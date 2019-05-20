module Runtime.RunCmd where

--------------------------------------------
import           Control.Monad.Trans.Class
import           Control.Monad.Reader
import qualified Data.List as L
import           Data.List.NonEmpty
import qualified Data.Map as M
import qualified System.Directory as Dir
--------------------------------------------
import           Data.Aeson.Orphans ()
import           HGit.Core.Diff (diffMerkleDirs, Diff)
import           HGit.Core.Merge (mergeMerkleDirs, commitMerge)
import           HGit.Core.Types
import           Runtime.Capabilities
import           Runtime.Commands
import           Runtime.FileIO
import           Runtime.Types
import           Util.RecursionSchemes
import           Merkle.Functors
import           Merkle.Store (liftStore, uploadDeep)
import           Merkle.Store.IPFS
import           Merkle.Store.Deref
--------------------------------------------

initRepo :: IPFSNode -> IO ()
initRepo ipfsNode = do
  nullCommit <- (unPutCapability $ snd $ ipfsStore ipfsNode) NullCommit
  writeState $ initialRepoState nullCommit

checkoutBranch :: BranchName -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
checkoutBranch bn = do
  dirStore <- asks (liftStore lift . _dirStore . rcStore)
  commitStore <- asks (liftStore lift . _commitStore . rcStore)

  targetCommit <- getBranch bn >>= sDeref' (fst commitStore)
  diffs        <- status

  if not (null diffs)
    then do
      liftIO $ putStrLn "directory modified, cannot checkout. Blocking changes:"
      _ <- traverse printDiff diffs
      pure Nothing
    else do
      currentCommit <- asks (currentBranch . rcState) >>= getBranch >>= sDeref' (fst commitStore)
      topLevelCurrentDir <- commitRoot currentCommit >>= sDeref' (fst dirStore)

      currentCommitRootDir <- commitRoot targetCommit
      setDirTo topLevelCurrentDir currentCommitRootDir

      asks (Just . (\r -> r { currentBranch = bn
                            }
                    ) . rcState)

mkBranch :: BranchName -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
mkBranch bn = do
  current <- asks (currentBranch . rcState) >>= getBranch
  asks (Just . (\r -> r { branches = M.insert bn current $ branches r
                        , currentBranch = bn
                        }
                ) . rcState)

mkCommit :: String -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
mkCommit msg = do
  blobStore <- asks (liftStore lift . _blobStore . rcStore)
  dirStore <- asks (liftStore lift . _dirStore . rcStore)
  commitStore <- asks (liftStore lift . _commitStore . rcStore)
  baseDir <- asks rcBaseDir

  currentCommitHash <- asks (currentBranch . rcState) >>= getBranch

  let uploadBlob  = uploadDeep (snd blobStore)
      uploadBlobs = bitraverseFix uploadBlob

  currentStateHash <- liftIO (readTree baseDir) >>= uploadBlobs >>= uploadDeep (snd dirStore)

  let commit = Commit msg currentStateHash (pure currentCommitHash)
  rootHash <- (unPutCapability $ snd commitStore) commit

  asks (Just . (\r -> r { branches = M.insert (currentBranch r) rootHash $ branches r
                        }
                ) . rcState)

mkMergeCommit :: BranchName -> String -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
mkMergeCommit targetBranch msg = do
  dirStore <- asks (liftStore lift . _dirStore . rcStore)
  commitStore <- asks (liftStore lift . _commitStore . rcStore)

  diffs <- status

  if not (null diffs)
    then do
      liftIO $ putStrLn "directory modified, cannot merge. Changes:"
      _ <- traverse printDiff diffs
      pure Nothing
    else do
      targetCommitHash  <- getBranch targetBranch
      currentCommitHash <- asks (currentBranch . rcState) >>= getBranch

      currentCommitRootDir <- sDeref' (fst commitStore) currentCommitHash >>= commitRoot
      targetCommitRootDir  <- sDeref' (fst commitStore) targetCommitHash >>= commitRoot

      mergeRes <- mergeMerkleDirs (lazyDeref' (fst dirStore) currentCommitRootDir)
                                  (lazyDeref' (fst dirStore) targetCommitRootDir)

      case mergeRes of
        Left err -> liftIO . fail $ "merge nonviable due to: " ++ show err
        Right rootDir'-> do
          rootDir <- commitMerge (snd dirStore) rootDir'
          let commit = Commit msg (htPointer rootDir) $ currentCommitHash :| [targetCommitHash]
          commitHash <- (unPutCapability $ snd commitStore) commit

          topLevelCurrentDir <- sDeref' (fst dirStore) currentCommitRootDir

          setDirTo topLevelCurrentDir $ htPointer rootDir

          asks (Just . (\r -> r { branches = M.insert (currentBranch r) commitHash $ branches r
                                }
                       ) . rcState)

getDiff :: BranchName -> BranchName -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
getDiff bn1 bn2 = do
    commitStore <- asks (liftStore lift . _commitStore . rcStore)
    dirStore <- asks (liftStore lift . _dirStore . rcStore)

    commit1RootDir <- getBranch bn1 >>= sDeref' (fst commitStore) >>= commitRoot
    commit2RootDir <- getBranch bn2 >>= sDeref' (fst commitStore) >>= commitRoot
    diffs     <- diffMerkleDirs (lazyDeref' (fst dirStore) commit1RootDir)
                                (lazyDeref' (fst dirStore) commit2RootDir)
    _ <- traverse printDiff diffs
    pure Nothing


runCommand :: RepoCommand -> ReaderT (RepoCaps IO) IO (Maybe RepoState)
runCommand = \case
  CheckoutBranch bn -> checkoutBranch bn
  MkBranch bn -> mkBranch bn
  MkCommit msg -> mkCommit msg

  -- todo: n-way merge
  MkMergeCommit bn msg -> mkMergeCommit bn msg

  GetStatus -> do
    diffs  <- status

    asks (currentBranch . rcState) >>= liftIO . putStrLn . ("current branch: " ++)
    liftIO $ putStrLn $ "diffs:"
    _ <- traverse printDiff diffs
    pure Nothing

  GetDiff bn1 bn2 -> getDiff bn1 bn2


printDiff :: MonadIO m => ([FilePath], Diff) -> m ()
printDiff (fps, d) = liftIO . putStrLn $ "\t" ++ show d ++ " at " ++ (L.intercalate "/" fps)

status :: ReaderT (RepoCaps IO) IO [([PartialFilePath], Diff)]
status = do
  baseDir <- asks rcBaseDir
  blobStore <- asks (liftStore lift . _blobStore . rcStore)
  dirStore <- asks (liftStore lift . _dirStore . rcStore)
  commitStore <- asks (liftStore lift . _commitStore . rcStore)
  currentCommit <- asks (currentBranch . rcState) >>= getBranch >>= sDeref' (fst commitStore)

  strictCurrentState  <- liftIO $ readTree baseDir

  -- FIXME: need to actually upload here to get IPFS hashes, currently. Seems inefficent
  currentState <- bitraverseFix (uploadDeep (snd blobStore)) strictCurrentState
              >>= uploadDeep (snd dirStore)


  -- FIXME: need to upload a null dir to get that thing's hash, should have null/0 hash case
  commitRootDir <- commitRoot currentCommit

  diffMerkleDirs (lazyDeref' (fst dirStore) commitRootDir)
                 (lazyDeref' (fst dirStore) currentState)


-- x, y, don't matter..
setDirTo :: forall x y. Dir x y -> Hash HashableDir -> ReaderT (RepoCaps IO) IO ()
setDirTo topLevelCurrentDir targetDir = do
  blobStore <- asks (liftStore lift . _blobStore . rcStore)
  dirStore <- asks (liftStore lift . _dirStore . rcStore)
  baseDir <- asks rcBaseDir


  let toDelete = dirEntries topLevelCurrentDir

  -- NOTE: basically only use in a docker container for a bit, lol
  -- delete each top-level entity in the current commit's root dir
  -- we just confirmed that there are no diffs btween it and the current dir state
  let cleanup (p, DirEntity  _) = Dir.removeDirectoryRecursive p
      cleanup (p, FileEntity _) = Dir.removeFile p
  _ <- liftIO $ traverse cleanup toDelete

  -- TODO better names
  x <- fmap stripTags . strictDeref $ lazyDeref' (fst dirStore) targetDir
  x' <- bitraverseFix (fmap stripTags . strictDeref . lazyDeref' (fst blobStore)) x

  writeTree baseDir x'


commitRoot
  :: Monad m -- using monad fail <- FIXME
  => HashableCommit x
  -> m (Hash HashableDir)
commitRoot (Commit _ x _) = pure x
commitRoot NullCommit     = fail "can't get commit root dir for Null Commit" -- FIXME