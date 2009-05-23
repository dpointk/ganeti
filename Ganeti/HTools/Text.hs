{-| Parsing data from text-files

This module holds the code for loading the cluster state from text
files, as produced by gnt-node/gnt-instance list.

-}

module Ganeti.HTools.Text
    where

import Control.Monad

import Ganeti.HTools.Utils
import Ganeti.HTools.Loader
import Ganeti.HTools.Types
import qualified Ganeti.HTools.Node as Node
import qualified Ganeti.HTools.Instance as Instance

-- | Safe 'read' function returning data encapsulated in a Result
tryRead :: (Monad m, Read a) => String -> String -> m a
tryRead name s =
    let sols = readsPrec 0 s
    in case sols of
         (v, ""):[] -> return v
         (_, e):[] -> fail $ name ++ ": leftover characters when parsing '"
                      ++ s ++ "': '" ++ e ++ "'"
         _ -> fail $ name ++ ": cannot parse string '" ++ s ++ "'"

-- | Load a node from a field list
loadNode :: (Monad m) => [String] -> m (String, Node.Node)
loadNode (name:tm:nm:fm:td:fd:fo:[]) = do
  new_node <-
      if any (== "?") [tm,nm,fm,td,fd] || fo == "Y" then
          return $ Node.create name 0 0 0 0 0 True
      else do
        vtm <- tryRead name tm
        vnm <- tryRead name nm
        vfm <- tryRead name fm
        vtd <- tryRead name td
        vfd <- tryRead name fd
        return $ Node.create name vtm vnm vfm vtd vfd False
  return (name, new_node)
loadNode s = fail $ "Invalid/incomplete node data: '" ++ (show s) ++ "'"

-- | Load an instance from a field list
loadInst :: (Monad m) =>
            [(String, Int)] -> [String] -> m (String, Instance.Instance)
loadInst ktn (name:mem:dsk:status:pnode:snode:[]) = do
  pidx <- lookupNode ktn name pnode
  sidx <- (if null snode then return Node.noSecondary
           else lookupNode ktn name snode)
  vmem <- tryRead name mem
  vdsk <- tryRead name dsk
  when (sidx == pidx) $ fail $ "Instance " ++ name ++
           " has same primary and secondary node - " ++ pnode
  let newinst = Instance.create name vmem vdsk status pidx sidx
  return (name, newinst)
loadInst _ s = fail $ "Invalid/incomplete instance data: '" ++ (show s) ++ "'"

{- | Convert newline and delimiter-separated text.

This function converts a text in tabular format as generated by
@gnt-instance list@ and @gnt-node list@ to a list of objects using a
supplied conversion function.

-}
loadTabular :: (Monad m, Element a) =>
               String -> ([String] -> m (String, a))
            -> m ([(String, Int)], [(Int, a)])
loadTabular text_data convert_fn = do
  let lines_data = lines text_data
      rows = map (sepSplit '|') lines_data
  kerows <- mapM convert_fn rows
  return $ assignIndices kerows

loadData :: String -- ^ Node data in string format
         -> String -- ^ Instance data in string format
         -> IO (Result (NameAssoc, Node.AssocList,
                        NameAssoc, Instance.AssocList))
loadData nfile ifile = do -- IO monad
  ndata <- readFile nfile
  idata <- readFile ifile
  return $ do
    {- node file: name t_mem n_mem f_mem t_disk f_disk -}
    (ktn, nl) <- loadTabular ndata loadNode
    {- instance file: name mem disk status pnode snode -}
    (kti, il) <- loadTabular idata (loadInst ktn)
    return (ktn, nl, kti, il)
