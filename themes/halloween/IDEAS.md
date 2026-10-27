# Halloween theme: ideas and interactions

The idea list with each idea's status is in [ideas.csv](ideas.csv): character, idea, status (done / partly / to do / dropped), how it's done (or the plan), and the preview key in the sim. This page explains how things work and has the interaction matrix.

## Roadmap

The order the open ideas are worked in. Feedback from watching the sim goes first, always.

1. **Machinery: one meeting table.** (A meets B → reaction, chance), checked from one proximity loop. Move the existing pairs in: zombie/skeleton, wolf/skeleton, zombie/werewolf man. This makes every gag below cheaper to add.
2. **Code-only gags, using existing art:**
   - The princess no longer turns herself into a frog.
   - A frog's kiss turns her into a frog sometimes.
   - The witch kisses her into a frog.
   - When the witch is wanted, a raven flies over fast and turns into her.
   - Open pairs from the matrix as one-line entries.
3. **Coffins:**
   - The princess vampire finds a coffin and lies down; it sinks.
   - Vampire and princess vampire share one coffin, which wiggles.
   - Needs a lying princess-vampire bake (small).
4. **New procedural art:** made in parallel by bake helpers while 1–3 are coded.
   - Bat (fly, hang, transform both ways) → vampire ↔ bat.
   - Window creep (octopus-like).
   - Mirror → the princess looks in.
5. **Model rework, needs your eye:** Frankenstein's look (hair, stitches, facing us) and the cat.

## How it works

Every story is either a planned **scene** or a meeting between characters that are already **about**. Interactions should be opportunistic: anything nearby that could set off a reaction does so. Planned scenes are the backbone, but each step looks for a nearby trigger first.

- **Scenes** are planned acts with a fixed script: witch, werewolf, princess, mummy, vampire, Frankenstein, frogs, pumpkin-head. A planner (`plan_tick`) picks the next scene for each screen.
- **The cast** are characters that stay about after their act (cast wanderers with a `ttl`). They walk from screen to screen, meet others, and can be recruited into a scene (`el.recruits`). A busy one (`a.busy`) is left alone.
- **Relics** are things left lying about: a bone, a pumpkin, a piece of brain, an eye, and Frankenstein's or a zombie's head, body and limbs. Others pick them up, carry them, wear them or eat them. A relic sinks into the ground after a while.
- **Hand-overs**: a walker or relic that leaves one screen arrives on the next one over the room bus. Skeletons and zombies can travel underground for a few screens.
- **Ways out**: when a cast member's time is up (`ttl`), it tries to leave gracefully: walking off, going underground, or a sarcophagus coming up for it. After 10 s it leaves by a cheat: a frog, a raven, or digging in.

## Interaction matrix

What happens when the row character meets the column one. ✓ = done, ○ = idea, empty = nothing yet (a candidate for a new trigger).

| Meets → | Witch | Werewolf | Princess | Vampire | Zombie | Skeleton | Mummy / sarcophagus | Frankenstein | Pumpkin-head | Cat |
|---|---|---|---|---|---|---|---|---|---|---|
| **Witch** | | | ✓ swap spell; ✓ a spell: she's a frog | | ✓ a spell: a frog | | ✓ trap | | ✓ her pumpkin-head | |
| **Werewolf** | | | ✓ turns her (she-wolf) | | ✓ the man is zombified | ✓ fight, bone | ✓ fight, bone; ✓ trap | ✓ takes limbs | | ✓ cat scares him |
| **She-wolf** | | | | | | ✓ takes bones | | ✓ takes limbs | | ✓ cat scares her |
| **Princess** | ✓ swap | ✓ turned; ✓ wakes him | | ✓ turned; ✓ kiss: frog | ✓ turned | ✓ prince | ✓ trap / pickup | ✓ prince | ✓ prince | |
| **Princess vampire** | | | ✓ mirror shows nothing | ✓ share a coffin | | | ✓ trap | | | |
| **Vampire** | | ✓ stand-off | ✓ bites / is kissed | ✓ a coffin for two | | | | | | ✓ cat on his coffin |
| **Zombie** | | ✓ gets the man | ✓ turns her | | ✓ eats a dropped brain; ✓ mends a zombie | ✓ fight: left in pieces | ✓ trap | ✓ sniffs him | | |
| **Skeleton** | | ✓ fight | ✓ prince | | ✓ fight: takes brain and eye | | ✓ helper; ✓ trap | | | |
| **Frankenstein** | | | ✓ prince | ✓ pushes his coffin | | | | | ✓ head worn by it | |
| **Mummy** | ✓ wraps her up | ✓ wraps him up | ✓ wraps her up | ✓ wraps him up | ✓ wraps it up | | | | ✓ wraps it up | |
| **Pumpkin-head** | | | ✓ prince | | | | ✓ trap | ✓ wears his head | ✓ takes a lying pumpkin | |

**Things lying about**:
- A bone: wolves take it, and a skeleton rises from it.
- Frankenstein's limbs: wolves take them.
- His head: a headless pumpkin-head wears it.
- A pumpkin: a headless pumpkin-head wears it.
- A piece of brain: a zombie eats it.
- A zombie's pieces: a zombie finding the head puts them back together; another zombie rises.
- An eye: a zombie pops it in; the cat bats it along (a bone too).

**Open pairs worth a trigger**:
- The cat with anyone but the wolves (it bats eyes and bones now).
- Frankenstein with a skeleton.

## Machinery

Each pair above is its own hand-written check. The reusable pieces are the dust fight (`hooks.dust_fight`), relics, swap/morph/puff, hand-overs, the sarcophagus pickup and the time-up exit.

The engine's main chunk is at Lua's 200-locals limit, so new helpers go on `hooks.*` or on tables. Plan: one table of meetings (A meets B → reaction and a chance), checked from a single proximity loop. Then each new gag is one entry.

## Art to-do

These need new or changed artwork (Blender bakes in `tools/bake`) before the engine work can follow.

- [x] **Frankenstein's look**: less hair so the stitches show, fewer clothes or clothes stitched together, and facing the viewer more so he reads as Frankenstein.
- [x] **Cat**: better animation. Either a baked 3D cat like the others, or the drawn cat with its shapes and proportions reworked.
- [x] **Bat for the vampire**: flying, hanging upside down, and a transform clip that also plays backwards.
- [x] **Mirror**: a standing mirror as decor. The reflection can be her own sprite, mirrored and dimmed.
- [x] **Window creep**: an octopus-like creature crawling past (along the floor: the videos have no window to crawl past).
- [x] **Princess vampire lying down**: for her own coffin, and a coffin big enough for two.
- [x] Zombie pieces, eye, skeleton head tracking (done for zombie vs skeleton).
