# Make a self-contained render copy of the v32 scene: images packed, MDD mesh caches repointed to //caches/<dir>/,
# sound removed from the frame output path concerns (frames only), output //out/f_####.png. Original untouched.
# usage: blender -b v32.blend -P prep_pack.py -- OUT.blend
import bpy, sys, os
OUT = sys.argv[sys.argv.index('--') + 1]
for im in bpy.data.images:
    if im.source == 'FILE' and not im.packed_file and im.filepath:
        try: im.pack()
        except Exception as e: print('PACKFAIL', im.name, e)
n = 0
for o in bpy.data.objects:
    for m in o.modifiers:
        if m.type == 'MESH_CACHE':
            p = bpy.path.abspath(m.filepath).replace(chr(92), '/'); d = os.path.basename(os.path.dirname(p))
            m.filepath = f'//caches/{d}/{os.path.basename(p)}'; n += 1
sc = bpy.context.scene; r = sc.render
r.filepath = '//out/f_'; r.image_settings.file_format = 'PNG'; r.image_settings.color_mode = 'RGB'; r.image_settings.compression = 15
r.use_overwrite = False; r.use_placeholder = True
sc.frame_set(0)
bpy.ops.wm.save_as_mainfile(filepath=OUT, relative_remap=False)
print('PACKED caches repointed', n, 'images packed', sum(1 for i in bpy.data.images if i.packed_file))
