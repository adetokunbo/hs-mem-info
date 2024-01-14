{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : System.MemInfo
Copyright   : (c) 2023 Tim Emiola
Maintainer  : Tim Emiola <adetokunbo@emio.la>
SPDX-License-Identifier: BSD3

Implements a command that computes the memory usage of some processes
-}
module System.MemInfo (
  -- * implement the system command @printmem@
  getChoices,
  printProcs,

  -- * read @MemUsage@ directly
  LostPid (..),
  readMemUsage,
  readMemUsage',
  readForOnePid,

  -- * unfold @MemUsage@ in a stream
  unfoldMemUsageAfter',
  unfoldMemUsageAfter,
  unfoldMemUsage,

  -- * determine the process/program name
  nameFromExeOnly,
  nameFor,
  nameAsFullCmd,

  -- * index by program name or by processID
  ProcName,
  dropId,
  withPid,
) where

import Data.Bifunctor (Bifunctor (..))
import Data.Functor ((<&>))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Fmt (
  listF,
  (+|),
  (|+),
  (|++|),
 )
import System.Exit (exitFailure)
import System.MemInfo.Choices (Choices (..), getChoices)
import System.MemInfo.Prelude
import System.MemInfo.Print (
  AsCmdName (..),
  fmtAsHeader,
  fmtMemUsage,
  fmtOverall,
 )
import System.MemInfo.Proc (
  BadStatus (..),
  ExeInfo (..),
  MemUsage (..),
  PerProc (..),
  StatusInfo (..),
  amass,
  parseExeInfo,
  parseFromSmap,
  parseFromStatm,
  parseStatusInfo,
 )
import System.MemInfo.SysInfo (
  ResultBud (..),
  fmtRamFlaws,
  fmtSwapFlaws,
  mkResultBud,
 )
import System.Posix.User (getEffectiveUserID)


-- | Report on the memory usage of the processes specified by @Choices@
printProcs :: Choices -> IO ()
printProcs cs = do
  bud <- verify cs
  let showSwap = choiceShowSwap cs
      onlyTotal = choiceOnlyTotal cs
      printEachCmd totals = printMemUsages bud showSwap onlyTotal totals
      printTheTotal = onlyPrintTotal bud showSwap onlyTotal
      showTotal cmds = if onlyTotal then printTheTotal cmds else printEachCmd cmds
      namer = if choiceSplitArgs cs then nameAsFullCmd else nameFor
  if choiceByPid cs
    then case choiceWatchSecs cs of
      Nothing -> readMemUsage' namer withPid bud >>= either haltLostPid showTotal
      Just spanSecs -> do
        let unfold = unfoldMemUsageAfter' namer withPid spanSecs
        loopPrintMemUsages unfold bud showTotal
    else case choiceWatchSecs cs of
      Nothing -> readMemUsage' namer dropId bud >>= either haltLostPid showTotal
      Just spanSecs -> do
        let unfold = unfoldMemUsageAfter' namer dropId spanSecs
        loopPrintMemUsages unfold bud showTotal


printMemUsages :: AsCmdName a => ResultBud -> Bool -> Bool -> Map a MemUsage -> IO ()
printMemUsages bud showSwap onlyTotal totals = do
  let overall = overallTotals $ Map.elems totals
      overallIsAccurate = (showSwap && rbHasSwapPss bud) || rbHasPss bud
      print' (name, stats) = Text.putStrLn $ fmtMemUsage showSwap name stats
  Text.putStrLn $ fmtAsHeader showSwap
  mapM_ print' $ Map.toList totals
  when overallIsAccurate $ Text.putStrLn $ fmtOverall showSwap overall
  reportFlaws bud showSwap onlyTotal


onlyPrintTotal :: ResultBud -> Bool -> Bool -> Map k MemUsage -> IO ()
onlyPrintTotal bud showSwap onlyTotal totals = do
  let (private, swap) = overallTotals $ Map.elems totals
      printRawTotal = Text.putStrLn . fmtMemBytes
  if showSwap
    then do
      when (rbHasSwapPss bud) $ printRawTotal swap
      reportFlaws bud showSwap onlyTotal
      when (isJust $ rbSwapFlaws bud) exitFailure
    else do
      when (rbHasPss bud) $ printRawTotal private
      reportFlaws bud showSwap onlyTotal
      when (isJust $ rbRamFlaws bud) exitFailure


loopPrintMemUsages ::
  (Ord c, AsCmdName c) =>
  (ResultBud -> IO (Either [ProcessID] ((Map c MemUsage, [ProcessID]), ResultBud))) ->
  ResultBud ->
  (Map c MemUsage -> IO ()) ->
  IO ()
loopPrintMemUsages unfold bud showTotal = do
  let clearScreen = putStrLn "\o033c"
      warnHalting = errStrLn False "halting: all monitored processes have stopped"
      handleNext (Left stopped) = do
        warnStopped stopped
        warnHalting
      handleNext (Right ((total, stopped), updated)) = do
        clearScreen
        warnStopped stopped
        showTotal total
        go updated
      go initial = unfold initial >>= handleNext
  go bud


warnStopped :: [ProcessID] -> IO ()
warnStopped pids = unless (null pids) $ do
  let errMsg = "some processes stopped:pids:" +| toInteger <$> pids |+ ""
  errStrLn False errMsg


-- | The name of a process or program in the memory report.
type ProcName = Text


{- | Like @'unfoldMemUsageAfter'@, using the default choices for indexing
programs/processes
-}
unfoldMemUsageAfter ::
  (Integral seconds) =>
  seconds ->
  ResultBud ->
  IO (Either [ProcessID] ((Map Text MemUsage, [ProcessID]), ResultBud))
unfoldMemUsageAfter = unfoldMemUsageAfter' nameFor dropId


-- | Like @'unfoldMemUsage'@ but computes the @'MemUsage's@ after a delay
unfoldMemUsageAfter' ::
  (Ord a, Integral seconds) =>
  (ProcessID -> IO (Either LostPid ProcName)) ->
  ((ProcessID, ProcName, PerProc) -> (a, PerProc)) ->
  seconds ->
  ResultBud ->
  IO (Either [ProcessID] ((Map a MemUsage, [ProcessID]), ResultBud))
unfoldMemUsageAfter' namer mkCmd spanSecs bud = do
  let spanMicros = 1000000 * fromInteger (toInteger spanSecs)
  threadDelay spanMicros
  unfoldMemUsage namer mkCmd bud


{- | Unfold @'MemUsage's@ specified by a @'ResultBud'@

The @ProcessID@ of processes that have stopped are reported, both as part of
successful invocation viz the @[ProcessID]@ that is part of the @Right@, and
also as the value in the @Left@, which is the result when all of the specified
processes have stopped.
-}
unfoldMemUsage ::
  (Ord a) =>
  (ProcessID -> IO (Either LostPid ProcName)) ->
  ((ProcessID, ProcName, PerProc) -> (a, PerProc)) ->
  ResultBud ->
  IO (Either [ProcessID] ((Map a MemUsage, [ProcessID]), ResultBud))
unfoldMemUsage namer mkCmd bud = do
  let changePids rbPids = bud {rbPids}
      dropStopped t [] = Just t
      dropStopped ResultBud {rbPids = ps} stopped =
        changePids <$> nonEmpty (NE.filter (`notElem` stopped) ps)
      ResultBud {rbPids = pids, rbHasPss = hasPss} = bud
      nextState (stopped, []) = Left stopped
      nextState (stopped, xs) = case dropStopped bud stopped of
        Just updated -> Right ((amass hasPss (map mkCmd xs), stopped), updated)
        Nothing -> Left stopped
  nextState <$> foldlEitherM' (readNameAndStats namer bud) pids


-- | Load the @'MemUsage'@ specified by a @ProcessID@
readForOnePid :: ProcessID -> IO (Either LostPid (ProcName, MemUsage))
readForOnePid pid = do
  let onePid = pid :| []
      noProc = Left $ NoProc pid
      orNoProc = maybe noProc Right . Map.lookupMin
      orNoProc' = either Left orNoProc
  mkResultBud onePid >>= \case
    Left _ -> pure noProc
    Right bud -> readMemUsage bud <&> orNoProc'


{- | Like @'readMemUsage'@ but uses the default choices for indexing
programs/processes
-}
readMemUsage :: ResultBud -> IO (Either LostPid (Map ProcName MemUsage))
readMemUsage = readMemUsage' nameFor dropId


{- | Loads the @'MemUsage'@ specified by a @'ResultBud'@

Fails if

- the system does not have the expected /proc filesystem with memory records
- any of the processes in @'ResultBud'@ are missing or inaccessible
-}
readMemUsage' ::
  Ord a =>
  (ProcessID -> IO (Either LostPid ProcName)) ->
  ((ProcessID, ProcName, PerProc) -> (a, PerProc)) ->
  ResultBud ->
  IO (Either LostPid (Map a MemUsage))
readMemUsage' namer mkCmd bud = do
  let amass' cmds = amass (rbHasPss bud) $ map mkCmd cmds
  fmap amass' <$> foldlEitherM (readNameAndStats namer bud) (rbPids bud)


readNameAndStats ::
  (ProcessID -> IO (Either LostPid ProcName)) ->
  ResultBud ->
  ProcessID ->
  IO (Either LostPid (ProcessID, ProcName, PerProc))
readNameAndStats namer bud pid = do
  namer pid >>= \case
    Left e -> pure $ Left e
    Right name ->
      readMemStats bud pid >>= \case
        Left e -> pure $ Left e
        Right stats -> pure $ Right (pid, name, stats)


reportFlaws :: ResultBud -> Bool -> Bool -> IO ()
reportFlaws bud showSwap onlyTotal = do
  let reportSwap = errStrLn onlyTotal . fmtSwapFlaws
      reportRam = errStrLn onlyTotal . fmtRamFlaws
      (ram, swap) = (rbRamFlaws bud, rbSwapFlaws bud)
  -- when showSwap, report swap flaws
  -- unless (showSwap and onlyTotal), show ram flaws
  when showSwap $ maybe (pure ()) reportSwap swap
  unless (onlyTotal && showSwap) $ maybe (pure ()) reportRam ram


verify :: Choices -> IO ResultBud
verify cs = case choicePidsToShow cs of
  Just rbPids -> do
    -- halt if any specified pid cannot be accessed
    checkAllExist rbPids
    mkResultBud rbPids >>= either haltErr pure
  Nothing -> do
    -- if choicePidsToShow is Nothing, must be running as root
    isRoot' <- isRoot
    unless isRoot' $ haltErr "run as root when no pids are specified using -p"
    allKnownProcs >>= mkResultBud >>= either haltErr pure


procRoot :: String
procRoot = "/proc/"


pidPath :: String -> ProcessID -> FilePath
pidPath base pid = "" +| procRoot |++| toInteger pid |+ "/" +| base |+ ""


isRoot :: IO Bool
isRoot = (== 0) <$> getEffectiveUserID


{- |  pidExists returns false for any ProcessID that does not exist or cannot
be accessed
-}
pidExeExists :: ProcessID -> IO Bool
pidExeExists = fmap (either (const False) (const True)) . exeInfo


-- | Obtain the @ProcName@ as the full cmd path
nameAsFullCmd :: ProcessID -> IO (Either LostPid ProcName)
nameAsFullCmd pid = do
  let cmdlinePath = pidPath "cmdline" pid
      err = NoCmdLine pid
      recombine = Text.intercalate " " . NE.toList
      orLostPid = maybe (Left err) (Right . recombine)
  readUtf8Text cmdlinePath >>= (pure . orLostPid) . parseCmdline


-- | Obtain the @ProcName@ by examining the path linked by @{proc_root}/pid/exe@
nameFromExeOnly :: ProcessID -> IO (Either LostPid ProcName)
nameFromExeOnly pid = do
  exeInfo pid >>= \case
    Right i | not $ eiDeleted i -> pure $ Right $ baseName $ eiOriginal i
    -- when the exe bud ends with (deleted), the version of the exe used to
    -- invoke the process has been removed from the filesystem. Sometimes it has
    -- been updated; examining both the original bud and the version in
    -- cmdline help determine what occurred
    Right ExeInfo {eiOriginal = orig} ->
      exists orig >>= \case
        True -> pure $ Right $ baseName $ "" +| orig |+ " [updated]"
        _ -> do
          let cmdlinePath = pidPath "cmdline" pid
          readUtf8Text cmdlinePath <&> parseCmdline >>= \case
            Just (x :| _) -> do
              let addSuffix' b = x <> if b then " [updated]" else " [deleted]"
              Right . baseName . addSuffix' <$> exists x
            -- args should not be empty when {pid_root}/exe resolves to a
            -- path, it's an error if it is
            Nothing -> pure $ Left $ NoCmdLine pid
    Left e -> pure $ Left e


{- | Obtain the @ProcName@ by examining the path linked by @{proc_root}/pid/exe@
or its parent's name if that is a better match
-}
nameFor :: ProcessID -> IO (Either LostPid ProcName)
nameFor pid =
  nameFromExeOnly pid
    >>= either (pure . Left) (parentNameIfMatched pid)


parentNameIfMatched :: ProcessID -> Text -> IO (Either LostPid ProcName)
parentNameIfMatched pid candidate = do
  let isMatch = flip Text.isPrefixOf candidate . siName
  statusInfo pid >>= \case
    Left err -> pure $ Left err
    Right si | isMatch si -> pure $ Right candidate
    Right si ->
      nameFromExeOnly (siParent si) >>= \case
        Right n | n == candidate -> pure $ Right n
        _ -> pure $ Right $ siName si


{- | Represents reasons a specified @pid =`ProcessID`@ may be not have memory
records.
-}
data LostPid
  = NoExeFile ProcessID
  | NoStatusCmd ProcessID
  | NoStatusParent ProcessID
  | NoCmdLine ProcessID
  | BadStatm ProcessID
  | NoProc ProcessID
  deriving (Eq, Show)


fmtLostPid :: LostPid -> Text
fmtLostPid (NoStatusCmd pid) = "missing:no name in {proc_root}/" +| toInteger pid |+ "/status"
fmtLostPid (NoStatusParent pid) = "missing:no ppid in {proc_root}/" +| toInteger pid |+ "/status"
fmtLostPid (NoExeFile pid) = "missing:{proc_root}/" +| toInteger pid |+ "/exe"
fmtLostPid (NoCmdLine pid) = "missing:{proc_root}/" +| toInteger pid |+ "/cmdline"
fmtLostPid (NoProc pid) = "missing:memory records for pid:" +| toInteger pid |+ ""
fmtLostPid (BadStatm pid) = "missing:invalid memory record in {proc_root}/" +| toInteger pid |+ "/statm"


haltLostPid :: LostPid -> IO a
haltLostPid err = do
  Text.hPutStrLn stderr $ "halting due to " +| fmtLostPid err |+ ""
  exitFailure


exeInfo :: ProcessID -> IO (Either LostPid ExeInfo)
exeInfo pid = do
  let exePath = pidPath "exe" pid
      handledErr e = isDoesNotExistError e || isPermissionError e
      onIOE e = if handledErr e then pure (Left $ NoExeFile pid) else throwIO e
  handle onIOE $ do
    Right . parseExeInfo . Text.pack <$> getSymbolicLinkTarget exePath


exists :: Text -> IO Bool
exists = doesFileExist . Text.unpack


statusInfo :: ProcessID -> IO (Either LostPid StatusInfo)
statusInfo pid = do
  let statusPath = pidPath "status" pid
      fromBadStatus NoCmd = NoStatusCmd pid
      fromBadStatus NoParent = NoStatusParent pid
  first fromBadStatus . parseStatusInfo <$> readUtf8Text statusPath


parseCmdline :: Text -> Maybe (NonEmpty Text)
parseCmdline =
  let split' = Text.split isNullOrSpace . Text.strip . Text.dropWhileEnd isNull
   in nonEmpty . split'


nonExisting :: NonEmpty ProcessID -> IO [ProcessID]
nonExisting = filterM (fmap not . pidExeExists) . NE.toList


checkAllExist :: NonEmpty ProcessID -> IO ()
checkAllExist pids =
  nonExisting pids >>= \case
    [] -> pure ()
    xs -> haltErr $ "no records available for: " +| listF (toInteger <$> xs) |+ ""


allKnownProcs :: IO (NonEmpty ProcessID)
allKnownProcs =
  let readNaturals = fmap (mapMaybe readMaybe)
      orNoPids = flip maybe pure $ haltErr "could not find any process records"
   in readNaturals (listDirectory procRoot)
        >>= filterM pidExeExists
        >>= orNoPids . nonEmpty


baseName :: Text -> Text
baseName = Text.pack . takeBaseName . Text.unpack


readMemStats :: ResultBud -> ProcessID -> IO (Either LostPid PerProc)
readMemStats bud pid = do
  statmExists <- doesFileExist $ pidPath "statm" pid
  if
      | rbHasSmaps bud -> Right . parseFromSmap <$> readSmaps pid
      | statmExists -> do
          let readStatm' = readUtf8Text $ pidPath "statm" pid
              orLostPid = maybe (Left $ BadStatm pid) Right
          orLostPid . parseFromStatm (rbKernel bud) <$> readStatm'
      | otherwise -> pure $ Left $ NoProc pid


readSmaps :: ProcessID -> IO Text
readSmaps pid = do
  let smapPath = pidPath "smaps" pid
      rollupPath = pidPath "smaps_rollup" pid
  hasSmaps <- doesFileExist smapPath
  hasRollup <- doesFileExist rollupPath
  if
      | hasRollup -> readUtf8Text rollupPath
      | hasSmaps -> readUtf8Text smapPath
      | otherwise -> pure Text.empty


overallTotals :: [MemUsage] -> (Int, Int)
overallTotals cts =
  let step (private, swap) ct = (private + muPrivate ct, swap + muSwap ct)
   in foldl' step (0, 0) cts


fmtMemBytes :: Int -> Text
fmtMemBytes x = "" +| x * 1024 |+ ""


foldlEitherM ::
  (Foldable t, Monad m) =>
  (a -> m (Either b c)) ->
  t a ->
  m (Either b [c])
foldlEitherM f xs =
  let go (Left err) _ = pure $ Left err
      go (Right acc) a =
        f a >>= \case
          Left err -> pure $ Left err
          Right y -> pure $ Right (y : acc)
   in foldlM go (Right []) xs


foldlEitherM' ::
  (Foldable t, Monad m) =>
  (a -> m (Either b c)) ->
  t a ->
  m ([a], [c])
foldlEitherM' f xs =
  let
    go (as, cs) a =
      f a >>= \case
        Left _ -> pure (a : as, cs)
        Right c -> pure (as, c : cs)
   in
    foldlM go (mempty, mempty) xs


haltErr :: Text -> IO a
haltErr err = do
  errStrLn True err
  exitFailure


errStrLn :: Bool -> Text -> IO ()
errStrLn errOrWarn txt = do
  let prefix = if errOrWarn then "error: " else "warning: "
  Text.hPutStrLn stderr $ prefix <> txt


{- | Index a @'PerProc'@ using the program name and process ID.

All @PerProc's@ are distinct with the when added to the @MemUsage@
-}
withPid :: (ProcessID, ProcName, PerProc) -> ((ProcessID, ProcName), PerProc)
withPid (pid, name, pp) = ((pid, name), pp)


{- | Index a @'PerProc'@ using just the program name

@PerProc's@ with the same @ProcName@ will be merged when added to a @MemUsage@
-}
dropId :: (ProcessID, ProcName, PerProc) -> (ProcName, PerProc)
dropId (_pid, name, pp) = (name, pp)
