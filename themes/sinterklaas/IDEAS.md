# Sinterklaas theme: ideas and how it works

The idea list with status is in [ideas.csv](ideas.csv): character, idea, status, how, preview key.

## Cast rules

- Pieten are **roetveegpieten**: ordinary skin with a few soot smudges. No blackface, red lips, earrings or caricature.
- Sint: red robe and cape, white beard, red mitre with a gold cross, golden crozier.
- Ozosnel, the white horse (Quaternius CC0). `horse.py --plain` gives it without the saddle cloth (St Maarten can use it).

## Preview (kiosksim)

Run off the main screen:

    setsid Xvfb :92 -screen 0 1920x1080x24 &
    DISPLAY=:92 KIOSKSIM_VO="gpu --gpu-context=x11egl" KIOSKSIM_DIR=/tmp/kiosksim-sint \
      KIOSK_SPRITE_CACHE=/tmp/kiosksim-sint/cache tools/kiosksim/run.sh &
    KIOSKSIM_DIR=/tmp/kiosksim-sint KIOSKSIM_THEME=sinterklaas python3 tools/kiosksim/drive.py 5 idle 3

Keys: `1`..`9` set the level, `0` back to the calendar, `v` idle/video, `s` brings the performers (Sint, Pieten, Sint on the horse) now.

## Levels

- 1+: a shoe with a carrot, now and then a chocolate letter (bottom corners).
- 1-4: one Piet now and then; 3+: Sint on foot; 2+: Sint on his horse; 3+: presents in a corner.
- 4+: a few pepernoten tumbling down; 5+: a second Piet.
- 8: a shower of pepernoten, presents in both corners, everyone more often.

## Rebake

    # models and PYTHONPATH (numpy for the glTF importer): see the headers of horse.py and kaykit.py
    blender -b -P tools/bake/kaykit.py -- tools/bake/recipes/sint.json themes/sinterklaas/anim/sint
    blender -b -P tools/bake/kaykit.py -- tools/bake/recipes/piet.json themes/sinterklaas/anim/piet
    python3 tools/bake/piet_variants.py            # piet_b, piet_c, piet_d recipes
    blender -b -P tools/bake/horse.py -- themes/sinterklaas/anim [384] [--plain]
    blender -b -P tools/bake/kaykit.py -- tools/bake/recipes/sint_ride.json ~/.cache/kioskplayer/bake/sint_ride 443
    python3 tools/bake/ride.py tools/bake/recipes/sint_horse.ride.json themes/sinterklaas/anim/sint_horse
    python3 tools/bake/quantize.py themes/sinterklaas/anim/<dir>

Props (shoe, presents, letter, pepernoten) are AI images (homeai, project kiosk-sinterklaas, job 22fe3a1a80db), trimmed to their alpha.

## Roadmap

1. Steamboat for the arrival (intocht): slides in along the bottom with smoke from the funnel, Sint on deck. Only on arrival day once the scheduler hands the sub-event to the engine.
2. A Piet throws pepernoten: a burst from the hand during the throw clip.
3. Chimney / roof edge: a Piet climbs up and drops a present.
4. Pakjesavond (5 Dec): a sack of presents, Pieten leave presents behind.
5. Polish (see ideas.csv).
