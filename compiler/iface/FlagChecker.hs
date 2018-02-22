{-# LANGUAGE RecordWildCards #-}

-- | This module manages storing the various GHC option flags in a modules
-- interface file as part of the recompilation checking infrastructure.
module FlagChecker (
        fingerprintDynFlags
    ) where

import Binary
import BinIface ()
import DynFlags
import HscTypes
import Module
import Name
import Fingerprint
-- import Outputable

import qualified Data.IntSet as IntSet
import System.FilePath (normalise)

-- | Produce a fingerprint of a @DynFlags@ value. We only base
-- the finger print on important fields in @DynFlags@ so that
-- the recompilation checker can use this fingerprint.
fingerprintDynFlags :: DynFlags -> Module -> (BinHandle -> Name -> IO ())
                    -> IO Fingerprint

fingerprintDynFlags dflags@DynFlags{..} this_mod nameio =
    let mainis   = if mainModIs == this_mod then Just mainFunIs else Nothing
                      -- see #5878
        -- pkgopts  = (thisPackage dflags, sort $ packageFlags dflags)
        safeHs   = setSafeMode safeHaskell
        -- oflags   = sort $ filter filterOFlags $ flags dflags

        -- *all* the extension flags and the language
        lang = (fmap fromEnum language,
                IntSet.toList $ extensionFlags)

        -- -I, -D and -U flags affect CPP
        cpp = ( map normalise includePaths
            -- normalise: eliminate spurious differences due to "./foo" vs "foo"
              , picPOpts dflags
              , opt_P_signature dflags)
            -- See Note [Repeated -optP hashing]

        -- Note [path flags and recompilation]
        paths = [ hcSuf ]

        -- -fprof-auto etc.
        prof = if gopt Opt_SccProfilingOn dflags then fromEnum profAuto else 0

    in -- pprTrace "flags" (ppr (mainis, safeHs, lang, cpp, paths)) $
       computeFingerprint nameio (mainis, safeHs, lang, cpp, paths, prof)


{- Note [path flags and recompilation]

There are several flags that we deliberately omit from the
recompilation check; here we explain why.

-osuf, -odir, -hisuf, -hidir
  If GHC decides that it does not need to recompile, then
  it must have found an up-to-date .hi file and .o file.
  There is no point recording these flags - the user must
  have passed the correct ones.  Indeed, the user may
  have compiled the source file in one-shot mode using
  -o to specify the .o file, and then loaded it in GHCi
  using -odir.

-stubdir
  We omit this one because it is automatically set by -outputdir, and
  we don't want changes in -outputdir to automatically trigger
  recompilation.  This could be wrong, but only in very rare cases.

-i (importPaths)
  For the same reason as -osuf etc. above: if GHC decides not to
  recompile, then it must have already checked all the .hi files on
  which the current module depends, so it must have found them
  successfully.  It is occasionally useful to be able to cd to a
  different directory and use -i flags to enable GHC to find the .hi
  files; we don't want this to force recompilation.

The only path-related flag left is -hcsuf.
-}
{- Note [Repeated -optP hashing]
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We invoke fingerprintDynFlags for each compiled module to include
the hash of relevant DynFlags in the resulting interface file.
-optP (preprocessor) flags are part of that hash.
-optP flags can come from multiple places:

  1. -optP flags directly passed on command line.
  2. -optP flags implied by other flags. Eg. -DPROFILING implied by -prof.
  3. -optP flags added with {-# OPTIONS -optP-D__F__ #-} in a file.

When compiling many modules at once with many -optP command line arguments
the work of hashing -optP flags would be repeated. This can get expensive
and as noted on #14697 it can take 7% of time and 14% of allocations on
a real codebase.

The obvious solution is to cache the hash of -optP flags per GHC invocation.
However, one has to be careful there, as the flags that were added in 3. way
have to be accounted for.

The current strategy is as follows:

  1. Lazily compute the hash of sOpt_p in sOpt_P_fingerprint whenever sOpt_p
     is modified. This serves dual purpose. It ensures correctness for when
     we add per file -optP flags and lets us save work for when we don't.
  2. When computing the fingerprint in fingerprintDynFlags use the cached
     value *and* fingerprint the additional implied (see 2. above) -optP flags.
     This is relatively cheap and saves the headache of fingerprinting all
     the -optP flags and tracking all the places that could invalidate the
     cache.
-}
