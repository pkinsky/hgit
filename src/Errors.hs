module Errors where

--------------------------------------------
import           Control.Exception (Exception)
--------------------------------------------
import           Merkle.Types (RawHash)
import           HGit.Types.HGit (BranchName)
--------------------------------------------

data MerkleTreeLookupError
  = EntityNotFoundInStore RawHash
  deriving Show

instance Exception MerkleTreeLookupError


data RepoStateError
  = DecodeError String
  | BranchNotFound BranchName
  deriving Show

instance Exception RepoStateError

data FileReadError
  = FileReadError FilePath -- tried to read this path but failed (todo better errors? idk lol)
  deriving Show
