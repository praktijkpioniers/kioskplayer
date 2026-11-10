# St Maarten: status notes

## 2026-11-11: QUIET MODE (live on the day)
Testing on the day showed the full theme was far too crowded over the museum video, with no time left to
tune it. So for now the theme runs in **quiet mode**:

- The only animation: **one small child with a lantern walking across the screen** now and then (the
  `kid` element: n=1, every 120-240 s, no singing notes, no unlit/fire/LED gags). Kid sprites and their
  carry_/unlit_ lanterns are scaled to 70%.
- **Everything else is hidden** with `min`/`video_min` 99: moon, hanging lanterns, procession, beggars,
  rich man, St Martin, church, school, Dom + flag, houses, bonfire, cow, geese, teens, border walk,
  island, 11:11 parade, the geese flyover.
- Each changed element/sprite keeps its old values in a `_quiet_was` key.
- The preview keys (F5..F12) still force a gag in the sim; the calendar never starts them.

**Undo:** `git revert` the commit "St Maarten: quiet mode", or put the `_quiet_was` values back.

## Before turning the full theme on again (next year)
- Far fewer things on screen at once: the planner busy figure (86-91%) and 13-17 actors per screen were
  much too much. Aim for one act at a time, long empty gaps, and the video as the main content.
- Buildings were shrunk 2026-11-11 (church 93%->40% of screen height, school/houses ->30%, Dom 56->30%);
  they read as a toy village. Possibly symbolic doorways only, or no buildings.
- Undecided: big acts over the video at level 8 (`video_min` 8, set by the planner work) or off the video.
- St Martin look D doesn't read as an adult (make him ~25% taller than B, smaller head, longer legs); the
  V and H half-robes look too alike.
- Known gaps: tear clip barely moves the arms; H/V cut only on look D; school hand-over across screens untested.
