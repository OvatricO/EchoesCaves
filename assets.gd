@tool
extends RefCounted
# مساعد الأصول: بيدور على الملفات في المشروع بالاسم (حتى لو فولدر Assets مكتوب Assetss)،
# وبيحمّل الموديلات ويظبط حجمها وخاماتها.
#   const AS := preload("res://assets.gd")

# الشخصيات (السكنات). tex = ملف الخامة، weapon = السلاح (اختياري) وخامته.
const SKINS := [
	{"name": "Cleric",  "file": "Cleric.fbx",  "tex": "Cleric_Texture.png",  "weapon": "Cleric_Staff.fbx",  "wtex": "Cleric_Staff_Texture.png"},
	{"name": "Warrior", "file": "Warrior.fbx", "tex": "Warrior_Texture.png", "weapon": "Warrior_Sword.fbx", "wtex": "Warrior_Sword_Texture.png"},
	{"name": "Ranger",  "file": "Ranger.fbx",  "tex": "Ranger_Texture.png",  "weapon": "Ranger_Bow.fbx",    "wtex": "Ranger_Bow_Texture.png"},
	{"name": "Rogue",   "file": "Rogue.fbx",   "tex": "Rogue_Texture.png",   "weapon": "Rogue_Dagger.fbx",  "wtex": "Rogue_Dagger_Texture.png"},
	{"name": "Wizard",  "file": "Wizard.fbx",  "tex": "Wizard_Texture.png",  "weapon": "Wizard_Staff.fbx",  "wtex": "Wizard_Staff_Texture.png"},
	{"name": "Monk",    "file": "Monk.fbx",    "tex": "Monk_Texture.png",    "weapon": "",                  "wtex": ""},
]
const SKIN_PRICE := 49

# Pets (buy / equip in the Skin Changer, "Pets" page). They follow the owner.
const PETS := [
	{"id": "dog", "name": "Dog", "file": "dog-base", "price": 199, "height": 0.55},
	{"id": "cat", "name": "Cat", "file": "cat-base", "price": 149, "height": 0.4},
]


static func pet_def(id: String) -> Dictionary:
	for p in PETS:
		if p["id"] == id:
			return p
	return {}

static var _index: Dictionary = {}     # اسم الملف (حروف صغيرة) -> المسار
static var _scanned := false
static var _cache: Dictionary = {}     # مسار -> PackedScene


static func _scan(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.begins_with("."):
			f = d.get_next()
			continue
		if d.current_is_dir():
			_scan(dir_path.path_join(f))
		else:
			# In an exported game the imported files show up as "name.fbx.import" / "name.png.remap":
			# strip the suffix so the normal path (which still loads fine) is indexed.
			var fname := f
			if fname.ends_with(".import"):
				fname = fname.trim_suffix(".import")
			elif fname.ends_with(".remap"):
				fname = fname.trim_suffix(".remap")
			var ext := fname.get_extension().to_lower()
			if ext in ["fbx", "png", "jpg", "jpeg", "gltf", "glb", "wav", "ogg", "mp3"]:
				_index[fname.to_lower()] = dir_path.path_join(fname)
		f = d.get_next()
	d.list_dir_end()


static func _ensure_index() -> void:
	if _scanned:
		return
	_scanned = true
	_scan("res://")


# بيدور على ملف اسمه (أو بيبدأ بـ) الكلمة دي، مثلا find("wolf-base") أو find("Cleric.fbx")
static func find(part: String) -> String:
	_ensure_index()
	var key := part.to_lower()
	if _index.has(key):
		return _index[key]
	for k in _index.keys():
		if (k as String).contains(key):
			return _index[k]
	return ""


static func load_scene(part: String) -> PackedScene:
	var p := find(part)
	if p == "":
		return null
	if _cache.has(p):
		return _cache[p]
	var res := load(p)
	if res is PackedScene:
		_cache[p] = res
		return res
	return null


static func load_texture(part: String) -> Texture2D:
	var p := find(part)
	if p == "":
		return null
	var t := load(p)
	return t as Texture2D


static func all_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(all_meshes(c))
	return out


static func find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := find_anim_player(c)
		if r != null:
			return r
	return null


static func find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := find_skeleton(c)
		if r != null:
			return r
	return null


# حجم كل المجسمات مجمّع (بوحدات الأب)، لتظبيط المقاس
static func _combined_aabb(root: Node3D) -> AABB:
	var first := true
	var box := AABB()
	for mi in all_meshes(root):
		var xf := _rel_transform(root, mi)
		var bb := xf * mi.get_aabb()
		if first:
			box = bb
			first = false
		else:
			box = box.merge(bb)
	return box


static func _rel_transform(root: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# بيعمل نسخة من الموديل مضبوطة الطول (target_height) وقدماها على y=0 ومركزها x/z=0
static func instance_fitted(part: String, target_height: float, use_longest: bool = false) -> Node3D:
	var ps := load_scene(part)
	if ps == null:
		return null
	var inst := ps.instantiate()
	var holder := Node3D.new()
	holder.name = "Fitted"
	holder.add_child(inst)
	if not (inst is Node3D):
		return holder
	var bb := _combined_aabb(holder)
	var h := bb.size.y
	if use_longest:
		h = maxf(bb.size.x, maxf(bb.size.y, bb.size.z))
	if h > 0.0001:
		var s := target_height / h
		(inst as Node3D).scale *= Vector3(s, s, s)
		bb = _combined_aabb(holder)
		(inst as Node3D).position -= Vector3(bb.get_center().x, bb.position.y, bb.get_center().z)
	return holder


static func apply_texture(root: Node, tex: Texture2D, unshaded: bool = false) -> void:
	if tex == null:
		return
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for mi in all_meshes(root):
		mi.material_override = m


# موديل شخصية جاهز (بخامته وسلاحه). بيرجع Node3D أو null لو الملف مش موجود.
static func make_character(skin_idx: int, height: float = 1.8) -> Node3D:
	skin_idx = clampi(skin_idx, 0, SKINS.size() - 1)
	var s: Dictionary = SKINS[skin_idx]
	var model := instance_fitted(s["file"], height)
	if model == null:
		return null
	apply_texture(model, load_texture(s["tex"]))
	if s["weapon"] != "":
		var skel := find_skeleton(model)
		var grip := "Weapon.R"
		if skel != null and skel.find_bone(grip) < 0:
			grip = "Fist.R"
		if skel != null and skel.find_bone(grip) >= 0:
			var w := instance_fitted(s["weapon"], 0.9, true)
			if w != null:
				apply_texture(w, load_texture(s["wtex"]))
				var att := BoneAttachment3D.new()
				att.bone_name = grip
				skel.add_child(att)
				# الوزن يتظبط بحجم السكلتون
				var inv := _rel_transform(model, skel).basis.get_scale()
				w.scale = Vector3(1.0 / maxf(inv.x, 0.0001), 1.0 / maxf(inv.y, 0.0001), 1.0 / maxf(inv.z, 0.0001))
				w.position = Vector3.ZERO
				att.add_child(w)
	return model


# ---------- الأنيميشن: بيلاقي أنيميشن باسم ينتهي بـ (Walk مثلا) ----------
static func anim_name(ap: AnimationPlayer, suffix: String) -> String:
	if ap == null:
		return ""
	var low := suffix.to_lower()
	for a in ap.get_animation_list():
		var s := String(a).to_lower()
		if s == low or s.ends_with("|" + low) or s.ends_with("_" + low):
			return String(a)
	for a in ap.get_animation_list():
		if String(a).to_lower().contains(low):
			return String(a)
	return ""


static func set_loop(ap: AnimationPlayer, anim: String) -> void:
	if ap == null or anim == "":
		return
	var a := ap.get_animation(anim)
	if a != null:
		a.loop_mode = Animation.LOOP_LINEAR


# ---------- خطوط خارجية بيضاء (للاعب الأعمى فقط) ----------
# الأجسام العادية على layer 1. نسخ الخطوط على layer 20 وكاميرا الأعمى بترسم layer 20 بس.
const OUTLINE_LAYER := 1 << 19

static func add_outline(root: Node3D, width: float = 0.04) -> Array:
	var made: Array = []
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color(0, 0, 0)
	var white := StandardMaterial3D.new()
	white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color = Color(1, 1, 1)
	white.cull_mode = BaseMaterial3D.CULL_FRONT
	white.grow = true
	white.grow_amount = width
	for mi in all_meshes(root):
		if mi.layers == OUTLINE_LAYER:
			continue
		var parent := mi.get_parent()
		var body := mi.duplicate() as MeshInstance3D
		var hull := mi.duplicate() as MeshInstance3D
		body.material_override = black
		hull.material_override = white
		body.layers = OUTLINE_LAYER
		hull.layers = OUTLINE_LAYER
		body.name = mi.name + "_ob"
		hull.name = mi.name + "_oh"
		parent.add_child(body)
		parent.add_child(hull)
		made.append(body)
		made.append(hull)
	return made
