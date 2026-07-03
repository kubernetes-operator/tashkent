import os, re, sys
from pathlib import Path

ENGINE_VERSION = "shape-engine-v22-custom-intent"

def read_md(path):
    if not path:
        return ""
    p = Path(path)
    return p.read_text(encoding="utf-8", errors="ignore") if p.exists() else ""

def find_value(md, key, default=""):
    for pat in [rf"^- {re.escape(key)}:\s*(.+)$", rf"^\|\s*{re.escape(key)}\s*\|\s*(.+?)\s*\|$"]:
        m = re.search(pat, md, re.I | re.M)
        if m:
            return m.group(1).strip()
    return default

def find_number(md, key, default):
    m = re.search(r"[-+]?\d+(\.\d+)?", find_value(md, key, ""))
    return float(m.group(0)) if m else default

def bval(v):
    return str(v).strip().lower() in ["true", "yes", "y", "1", "allowed", "허용"]

def has(text, words):
    t = text.lower()
    return any(w.lower() in t for w in words)

def channels(text):
    t = text.lower()
    if any(x in t for x in ["3구", "3개", "three", "triple", "3 channel", "3-channel"]): return 3
    if any(x in t for x in ["2구", "2개", "two", "dual", "2 channel", "2-channel"]): return 2
    return 1

run_dir = Path(sys.argv[1])
product_md_path = sys.argv[2] if len(sys.argv) >= 3 else ""
md = read_md(product_md_path)

name = find_value(md, "Name", "Auto Generated Product")
category = find_value(md, "Category", "custom")
preset_id = find_value(md, "Preset ID", "custom")
desc = find_value(md, "Description", "")
shape = find_value(md, "Shape", "holder")
surface = find_value(md, "Surface", "matte")
material = find_value(md, "Material", "PETG")
mount = find_value(md, "Mount Type", "none")
support = bval(find_value(md, "Support Allowed", "false"))
gpu = os.environ.get("USE_GPU", "false").lower() == "true"
gpu_task = os.environ.get("GPU_TASK", "none")

w = max(30, min(find_number(md, "Width", 80), 260))
d = max(15, min(find_number(md, "Depth", 35), 190))
h = max(8, min(find_number(md, "Height", 25), 150))

cable_channels_explicit = int(max(1, min(find_number(md, "Cable Channels", 1), 6)))
cable_diameter_mm = max(1.0, min(find_number(md, "Cable Diameter", 6.0), 30.0))
magnet_diameter_mm = max(3.0, min(find_number(md, "Magnet Diameter", 10.0), 40.0))
magnet_thickness_mm = max(1.0, min(find_number(md, "Magnet Thickness", 2.0), 12.0))
hinge_count_explicit = int(max(1, min(find_number(md, "Hinge Count", 3), 8)))
clearance_mm = max(0.0, min(find_number(md, "Clearance", 0.3), 2.0))

blob = " ".join([name, category, preset_id, desc, shape, mount])
known = {"bambu_a1_nozzle_holder","bambu_scraper_holder","m3_wall_hook","cable_clip_small","homelab_label_holder","battery_case_2cell"}
if preset_id in known:
    profile = preset_id
elif has(blob, ["hinge","hinged","힌지","경첩","접히","fold"]):
    profile = "custom_hinged_case"
elif has(blob, ["lid","cover","뚜껑","커버","덮개"]):
    profile = "custom_lidded_case"
elif has(blob, ["magnet","magnetic","자석","마그넷"]):
    profile = "custom_magnetic_holder"
elif has(blob, ["cable","clip","케이블","클립"]):
    profile = "custom_cable_clip"
elif has(blob, ["bracket","브라켓","wall mount","벽걸이","m3","bolt","볼트","나사"]):
    profile = "custom_screw_bracket"
elif has(blob, ["tray","box","case","트레이","박스","케이스","수납"]):
    profile = "custom_open_tray"
else:
    profile = "custom_parametric_holder"

chan = cable_channels_explicit
grid_flag = has(blob + " " + surface, ["grid","격자"])
label_flag = has(blob, ["label","라벨","nameplate","네임"])
magnet_flag = has(blob + " " + mount, ["magnet","magnetic","자석","마그넷"])
base_t = max(3.2, min(h * 0.18, 6.0))
wall_t = 3.0
bevel = 1.5

blender = f'''
import bpy, math, sys
from pathlib import Path

ENGINE_VERSION = {ENGINE_VERSION!r}
run_dir = Path(sys.argv[sys.argv.index("--")+1])

P = {{
"name": {name!r}, "category": {category!r}, "preset_id": {preset_id!r},
"description": {desc!r}, "shape": {shape!r}, "surface": {surface!r},
"material": {material!r}, "mount": {mount!r}, "support": {support!r},
"w": {w!r}, "d": {d!r}, "h": {h!r}, "profile": {profile!r},
"channels": {chan!r}, "cable_diameter": {cable_diameter_mm!r}, "magnet_diameter": {magnet_diameter_mm!r}, "magnet_thickness": {magnet_thickness_mm!r}, "hinge_count": {hinge_count_explicit!r}, "clearance": {clearance_mm!r}, "grid": {grid_flag!r}, "label": {label_flag!r},
"magnet": {magnet_flag!r}, "gpu": {gpu!r}, "gpu_task": {gpu_task!r}
}}

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()
bpy.context.scene.unit_settings.system = "METRIC"
bpy.context.scene.unit_settings.scale_length = 0.001

def mat(n, rgba):
    m=bpy.data.materials.new(n); m.diffuse_color=rgba; return m
body=mat("body_"+P["material"], (0.06,0.06,0.06,1))
acc=mat("accent", (0.75,0.75,0.75,1))
dbg=mat("debug_blue", (0.1,0.25,0.9,1))

def cube(n, loc, dim, m=None, b=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o=bpy.context.object; o.name=n; o.dimensions=dim
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if m: o.data.materials.append(m)
    if b:
        be=o.modifiers.new("bevel","BEVEL"); be.width=b; be.segments=4
        o.modifiers.new("weighted_normals","WEIGHTED_NORMAL")
    return o

def cyl(n, loc, r, dep, m=None, vertices=64, rotation=(0,0,0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=r, depth=dep, location=loc, rotation=rotation)
    o=bpy.context.object; o.name=n
    if m: o.data.materials.append(m)
    o.modifiers.new("weighted_normals","WEIGHTED_NORMAL")
    return o

def txt(n, bodytxt, loc, size, m=None, rotation=(0,0,0)):
    bpy.ops.object.text_add(location=loc, rotation=rotation)
    o=bpy.context.object; o.name=n; o.data.body=bodytxt; o.data.align_x="CENTER"; o.data.align_y="CENTER"; o.data.size=size; o.data.extrude=.35
    if m: o.data.materials.append(m)
    return o

def cut(target, cutter):
    mod=target.modifiers.new("cut_"+cutter.name, "BOOLEAN"); mod.operation="DIFFERENCE"; mod.object=cutter
    bpy.context.view_layer.objects.active=target; target.select_set(True)
    try:
        bpy.ops.object.modifier_apply(modifier=mod.name); bpy.data.objects.remove(cutter, do_unlink=True)
    except Exception as e:
        print("[WARN] boolean failed", repr(e))

w,d,h=P["w"],P["d"],P["h"]; base_t={base_t!r}; wall_t={wall_t!r}; bevel={bevel!r}; profile=P["profile"]
notes=[]
cube("ENGINE_v22_MARKER", (-w/2+4,d/2-4,base_t+2), (5,5,4), dbg, .5)

if profile == "custom_hinged_case":
    shell=max(h*.45,12)
    cube("HINGED_BOTTOM_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    cube("HINGED_BOTTOM_BACK",(0,d/2-wall_t/2,base_t+shell/2),(w,wall_t,shell),body,bevel)
    cube("HINGED_BOTTOM_FRONT",(0,-d/2+wall_t/2,base_t+shell/2),(w,wall_t,shell),body,bevel)
    cube("HINGED_BOTTOM_LEFT",(-w/2+wall_t/2,0,base_t+shell/2),(wall_t,d,shell),body,bevel)
    cube("HINGED_BOTTOM_RIGHT",(w/2-wall_t/2,0,base_t+shell/2),(wall_t,d,shell),body,bevel)
    lid=cube("HINGED_LID_OPEN",(0,d*.15,h+base_t),(w,d,base_t),body,bevel); lid.rotation_euler[0]=math.radians(-15)
    hinge_count = int(P.get("hinge_count", 3))
    if hinge_count <= 1:
        hinge_positions = [0]
    else:
        hinge_positions = [(-w*0.38) + i*((w*0.76)/(hinge_count-1)) for i in range(hinge_count)]
    for i,x in enumerate(hinge_positions,1): cyl("HINGE_BARREL_"+str(i),(x,d/2+2,h*.72),2.6,max(w*.10,8),acc,48,(0,math.radians(90),0))
    cyl("HINGE_PIN",(0,d/2+2,h*.72),1.1,w*.86,dbg,48,(0,math.radians(90),0))
    notes+=["intent=hinged_case","hinge_barrels="+str(hinge_count)]

elif profile == "custom_lidded_case":
    wall=max(h*.55,12)
    cube("LIDDED_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    for n,loc,dim in [("BACK",(0,d/2-wall_t/2,base_t+wall/2),(w,wall_t,wall)),("FRONT",(0,-d/2+wall_t/2,base_t+wall/2),(w,wall_t,wall)),("LEFT",(-w/2+wall_t/2,0,base_t+wall/2),(wall_t,d,wall)),("RIGHT",(w/2-wall_t/2,0,base_t+wall/2),(wall_t,d,wall))]:
        cube("LIDDED_"+n,loc,dim,body,bevel)
    cube("SEPARATE_LID",(0,0,base_t+wall+base_t/2+2),(w*1.03,d*1.03,base_t),acc,bevel)
    cube("LID_INNER_RIM",(0,0,base_t+wall+base_t+2.6),(w*.82,d*.82,1.2),dbg,.5)
    notes+=["intent=lidded_case","separate_lid=yes"]

elif profile == "custom_magnetic_holder":
    base=cube("MAGNET_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    rail=max(h*.45,10)
    cube("MAGNET_BACK",(0,d/2-wall_t/2,base_t+rail/2),(w,wall_t,rail),body,bevel)
    cube("MAGNET_LEFT",(-w/2+wall_t/2,0,base_t+rail/2),(wall_t,d,rail),body,bevel)
    cube("MAGNET_RIGHT",(w/2-wall_t/2,0,base_t+rail/2),(wall_t,d,rail),body,bevel)
    for i,x in enumerate([-w*.25,w*.25],1):
        cut(base,cyl("MAGNET_SOCKET_CUT_"+str(i),(x,0,base_t+.8),P.get("magnet_diameter",10.0)/2 + P.get("clearance",0.3), P.get("magnet_thickness",2.0)+0.4, None,72))
        cyl("MAGNET_SOCKET_RING_"+str(i),(x,0,base_t+.2),P.get("magnet_diameter",10.0)/2 + P.get("clearance",0.3)+0.4, .3,acc,72)
    notes+=["intent=magnetic_holder","magnet_sockets=2"]

elif profile in ["custom_cable_clip","cable_clip_small"]:
    cube("CABLE_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    ch=P["channels"]; usable=w*.78; pitch=usable/max(ch,1); cw=max(P.get("cable_diameter",6.0)+P.get("clearance",0.3)*2, min(pitch*.55,18)); wh=max(h-base_t,10)
    for i in range(ch):
        cx=-usable/2+pitch/2+i*pitch
        cube("CABLE_"+str(i+1)+"_L",(cx-cw/2,0,base_t+wh/2),(wall_t*1.3,d*.75,wh),body,bevel)
        cube("CABLE_"+str(i+1)+"_R",(cx+cw/2,0,base_t+wh/2),(wall_t*1.3,d*.75,wh),body,bevel)
        cube("CABLE_"+str(i+1)+"_LIP_L",(cx-cw/2+wall_t*1.4,0,base_t+wh-wall_t/2),(wall_t*1.8,d*.55,wall_t),body,bevel)
        cube("CABLE_"+str(i+1)+"_LIP_R",(cx+cw/2-wall_t*1.4,0,base_t+wh-wall_t/2),(wall_t*1.8,d*.55,wall_t),body,bevel)
    cube("ADHESIVE_PAD",(0,0,base_t+.22),(w*.70,d*.52,.35),acc,.5)
    notes+=["intent=multi_cable_clip","channels="+str(ch)]

elif profile in ["custom_screw_bracket","m3_wall_hook"]:
    plate=cube("BRACKET_BACK_PLATE",(0,d/2-wall_t/2,h/2),(w,wall_t,h),body,bevel)
    for i,x in enumerate([-w*.30,w*.30],1):
        cut(plate,cyl("BRACKET_M3_CUT_"+str(i),(x,d/2-wall_t/2,h*.68),1.7,wall_t+3,None,72,(math.radians(90),0,0)))
        cyl("BRACKET_M3_RING_"+str(i),(x,d/2-wall_t-.08,h*.68),3.2,.15,acc,72,(math.radians(90),0,0))
    cube("BRACKET_SHELF",(0,-d*.18,h*.34),(w*.72,d*.70,base_t*1.4),body,bevel)
    cube("BRACKET_FRONT_LIP",(0,-d*.52,h*.34+8),(w*.72,wall_t*1.4,16),body,bevel)
    notes+=["intent=screw_bracket","m3_holes=2"]

elif profile in ["custom_open_tray","bambu_a1_nozzle_holder","battery_case_2cell"]:
    wall=max(h-base_t,10); base=cube("OPEN_TRAY_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    cube("TRAY_BACK",(0,d/2-wall_t/2,base_t+wall/2),(w,wall_t,wall),body,bevel)
    cube("TRAY_FRONT_LOW",(0,-d/2+wall_t/2,base_t+min(wall,10)/2),(w,wall_t,min(wall,10)),body,bevel)
    cube("TRAY_LEFT",(-w/2+wall_t/2,0,base_t+wall/2),(wall_t,d,wall),body,bevel)
    cube("TRAY_RIGHT",(w/2-wall_t/2,0,base_t+wall/2),(wall_t,d,wall),body,bevel)
    if profile=="bambu_a1_nozzle_holder":
        for i in range(6):
            x=-(w-20)/2+i*((w-20)/5); cut(base,cyl("NOZZLE_WELL_CUT_"+str(i+1),(x,-d*.05,base_t+1),4.2,3.2,None,72)); cyl("NOZZLE_RING_"+str(i+1),(x,-d*.05,base_t+.15),5,.25,acc,72)
        notes+=["intent=nozzle_tray","nozzle_wells=6"]
    elif profile=="battery_case_2cell":
        cube("BATTERY_DIVIDER",(0,0,base_t+wall*.42),(wall_t,d*.84,wall*.84),body,bevel)
        notes+=["intent=battery_case","slots=2"]
    else:
        notes+=["intent=open_tray"]

else:
    rail=max(h*.45,10)
    cube("HOLDER_BASE",(0,0,base_t/2),(w,d,base_t),body,bevel)
    cube("HOLDER_LEFT",(-w/2+wall_t/2,0,base_t+rail/2),(wall_t,d,rail),body,bevel)
    cube("HOLDER_RIGHT",(w/2-wall_t/2,0,base_t+rail/2),(wall_t,d,rail),body,bevel)
    cube("HOLDER_BACK",(0,d/2-wall_t/2,base_t+rail/2),(w,wall_t,rail),body,bevel)
    notes+=["intent=parametric_holder"]

if P["grid"]:
    for i in range(5):
        x=-w*.35+i*(w*.7/4); cube("GRID_X_"+str(i),(x,0,base_t+.3),(.7,d*.75,.45),acc,0)
    for j in range(3):
        y=-d*.25+j*(d*.5/2); cube("GRID_Y_"+str(j),(0,y,base_t+.35),(w*.75,.7,.45),acc,0)

if P["label"]:
    txt("FRONT_LABEL", P["name"][:16], (0,-d*.38,base_t+.8), max(min(w/16,6),3), acc)

meta=["engine_version="+ENGINE_VERSION,"name="+P["name"],"category="+P["category"],"preset_id="+P["preset_id"],"shape="+P["shape"],"surface="+P["surface"],"material="+P["material"],"mount_type="+P["mount"],"width_mm="+str(w),"depth_mm="+str(d),"height_mm="+str(h),"design_profile="+profile,"cable_channels="+str(P["channels"]),"cable_diameter_mm="+str(P.get("cable_diameter", "")),"magnet_diameter_mm="+str(P.get("magnet_diameter", "")),"magnet_thickness_mm="+str(P.get("magnet_thickness", "")),"hinge_count="+str(P.get("hinge_count", "")),"clearance_mm="+str(P.get("clearance", "")),"wants_grid="+str(P["grid"]),"wants_label="+str(P["label"]),"wants_magnet="+str(P["magnet"])]
meta.extend(notes)
(run_dir/"design_metadata.txt").write_text("\\n".join(meta), encoding="utf-8")
(run_dir/"shape_intent_debug.txt").write_text("\\n".join(["engine_version="+ENGINE_VERSION,"selected_profile="+profile,"notes="+" | ".join(notes),"shape="+P["shape"],"description="+P["description"]]), encoding="utf-8")

bpy.ops.object.light_add(type="AREA", location=(0,-140,170))
light=bpy.context.object; light.data.energy=550; light.data.size=85
bpy.ops.object.camera_add(location=(w*.85,-max(d*2.8,95),max(h*1.8,65)), rotation=(1.1,0,.42))
bpy.context.scene.camera=bpy.context.object
bpy.context.scene.render.resolution_x=1200; bpy.context.scene.render.resolution_y=900

render_mode="CPU"
try:
    bpy.context.scene.render.engine="CYCLES"; bpy.context.scene.cycles.samples=64
    if P["gpu"]:
        prefs=bpy.context.preferences; cp=prefs.addons["cycles"].preferences
        for backend in ["OPTIX","CUDA"]:
            try:
                cp.compute_device_type=backend; cp.get_devices()
                for dev in cp.devices: dev.use=True
                bpy.context.scene.cycles.device="GPU"; render_mode="GPU:"+backend; break
            except Exception: pass
except Exception as e:
    print("[WARN] render setup failed", repr(e)); render_mode="CPU_OR_EEVEE"

stl_path=str(run_dir/"model.stl"); blend_path=str(run_dir/"model.blend"); preview_path=str(run_dir/"preview.png")
try: bpy.ops.wm.stl_export(filepath=stl_path)
except Exception: bpy.ops.export_mesh.stl(filepath=stl_path)
bpy.ops.wm.save_as_mainfile(filepath=blend_path)
preview_status="not_rendered"
try:
    bpy.context.scene.render.filepath=preview_path; bpy.ops.render.render(write_still=True); preview_status="rendered:"+render_mode
except Exception as e:
    preview_status="failed:"+repr(e)

(run_dir/"output_status.txt").write_text("\\n".join(["engine_version="+ENGINE_VERSION,"stl_path="+stl_path,"blend_path="+blend_path,"preview_path="+preview_path,"preview_status="+preview_status,"render_mode="+render_mode,"design_profile="+profile]), encoding="utf-8")
print("[INFO] ENGINE_VERSION:", ENGINE_VERSION)
print("[INFO] Product:", P["name"])
print("[INFO] Profile:", profile)
print("[INFO] Notes:", " | ".join(notes))
'''

Path("/workspace/blender/generated_model.py").write_text(blender, encoding="utf-8")
print("[INFO] ENGINE_VERSION:", ENGINE_VERSION)
print("[INFO] name=", name)
print("[INFO] preset_id=", preset_id)
print("[INFO] shape=", shape)
print("[INFO] mount_type=", mount)
print("[INFO] design_profile=", profile)
print("[INFO] cable_channels=", chan)
