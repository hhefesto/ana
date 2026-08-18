-- The nested allocation arena's policy, separated from the CUDA calls that
-- enact it.  ProductionPieces holds device pointers and cannot be built
-- without a GPU toolchain; these rules can, so they are checked by the
-- conformance harness on any machine.
--
-- A frame stack is innermost-first; [] means no window is open and
-- allocations are caller-owned.  The invariant the rules maintain is that
-- every allocation is tracked by exactly one open frame until it is either
-- freed explicitly or released when its frame closes -- never zero frames
-- (a leak) and never two (a double free).
module Arena
  ( arenaPush
  , arenaRegister
  , arenaForget
  , arenaPop
  ) where

import Data.List (nub)

arenaPush :: [[a]] -> [[a]]
arenaPush = ([] :)

-- Outside a window an allocation is the caller's to free, so it is dropped
-- rather than tracked.
arenaRegister :: a -> [[a]] -> [[a]]
arenaRegister _ [] = []
arenaRegister pointer (frame : outer) = (pointer : frame) : outer

-- Called before an explicit free: the pointer must leave every frame, or the
-- close of whichever frame still held it would free it a second time.
arenaForget :: Eq a => a -> [[a]] -> [[a]]
arenaForget pointer = map (filter (/= pointer))

-- Closes the innermost window, returning the remaining stack and the
-- allocations to release.
--
-- Survivors escape to the caller.  One allocated in this frame becomes the
-- enclosing frame's responsibility -- without that promotion it would leak
-- when the enclosing frame closes.  One that came from further out is left
-- alone: it is already tracked there, and re-registering it would free it
-- twice.  At the outermost frame there is nowhere to promote to, so
-- survivors become caller-owned.
arenaPop :: Eq a => [a] -> [[a]] -> Maybe ([[a]], [a])
arenaPop _ [] = Nothing
arenaPop survivors (frame : outer) = Just (stack, released)
  where
    mine = nub frame
    released = [pointer | pointer <- mine, pointer `notElem` survivors]
    promoted = [pointer | pointer <- survivors, pointer `elem` mine]
    stack = case outer of
      [] -> []
      parent : rest -> (promoted ++ parent) : rest
