extends CharacterBody3D
# One player. Every player controls only his own body (multiplayer authority); the others see him via _sync_state.
# Roles: "lobby" (normal vision) | "carrier" (the BLIND player + flashlight) | "guide" (SIGHTED: tiny light bubble only)

const AS := preload("res://assets.gd")

const WALK_SPEED := 4.5
const SPRINT_MULT := 1.7          # Shift = faster walking
const SPRINT_TIME := 20.0         # seconds of sprint a full bar gives
const SPRINT_REFILL := 10.0       # seconds to refill; the ability is locked until the bar is full again
const CROUCH_SPEED := 2.0
const JUMP_VELOCITY := 4.6
const REMOTE_LERP := 14.0
const MAX_HP := 100.0
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.15
const MODEL_YAW := PI              # if the character walks backwards, change this to 0.0

# Movement feel. Lower values = softer start/stop (this is what removes the foot "snap" when you let go of a key).
const ACCEL := 7.0                 # speed * ACCEL  (m/s^2)
const DECEL := 6.0

# ---- SIGHTED PLAYER VISION (tune here) ----
# A small light bubble around the sighted player: you can barely see the floor/walls within ~1 m.
# Smaller SIGHT_RANGE = smaller bubble. Bigger SIGHT_ENERGY = brighter bubble.
const SIGHT_RANGE := 1.7
const SIGHT_ENERGY := 2.2
const SIGHT_ATTENUATION := 1.3
const SIGHT_HEIGHT := 0.5          # light height above the floor (metres)

# ---- BLIND PLAYER FLASHLIGHT = the main light source for the whole team ----
const FLASH_RANGE := 28.0
const FLASH_ENERGY := 6.0
const FLASH_ANGLE := 38.0

# Collision layers: 1 = world, 2 = creatures, 4 = solid decor (players collide, interaction rays pass through), 8 = loot
const DECOR_LAYER := 4

signal died
signal hp_changed(hp: float)
signal throw_requested(origin: Vector3, direction: Vector3)
signal sprint_changed(value: float, locked: bool)
signal primary_action               # Left Click while the mouse is captured (hit / collect what the crosshair points at)

var role := "lobby"
var is_carrier := false
var frozen := false          # while dead / before start / UI open
var ui_open := false
var sync_enabled := false
var flashlight_on := true
var hp := MAX_HP
var stones := 0
var skin_idx := 0
var sprint_energy := 1.0
var sprint_locked := false
var sprinting := false
var grabbed_by: Node3D = null      # the duck carrying me (set by the duck)
var has_sword := false
var _sword: Node3D = null
var _launch_t := 0.0
var _launch_v := Vector3.ZERO
var _foot: AudioStreamPlayer3D
var crouching := false
var moving := false
var ping_noise_t := 0.0            # > 0 while the blind player's Echo Ping is audible to monsters
var _senses: Node = null

var _has_state := false
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0
var _last_skin := -1
var _shape: CapsuleShape3D
var _walk_name := ""
var _run_name := ""
var _sneak_name := ""
var _idle_name := ""
var _attack_name := ""
var _hit_name := ""
var _death_name := ""
var _cur_clip := ""
var _one_shot_t := 0.0
var _height_cur := STAND_HEIGHT
var _speed_smooth := 0.0     # smoothed horizontal speed that drives the animation
var _is_moving_anim := false
var _prev_pos := Vector3.ZERO
var _remote_speed := 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/SpotLight3D
@onready var guide_light: OmniLight3D = $Head/GuideLight
@onready var model_root: Node3D = $Model
@onready var col: CollisionShape3D = $CollisionShape3D
var anim: AnimationPlayer
var name_label: Label3D


# called before add_child
func setup(peer_id: int, p_role: String) -> void:
	name = str(peer_id)
	set_multiplayer_authority(peer_id)
	role = p_role
	is_carrier = (role == "carrier")


func _ready() -> void:
	add_to_group("players")
	if is_multiplayer_authority():
		pet_id = GameNet.equipped_pet
	collision_mask = 1 | DECOR_LAYER
	_shape = CapsuleShape3D.new()
	_shape.radius = 0.35
	_shape.height = STAND_HEIGHT
	col.shape = _shape
	_setup_lights()
	if is_multiplayer_authority():
		skin_idx = GameNet.equipped_skin
	_rebuild_model()
	_apply_role()
	if pet_id != "":
		call_deferred("set_pet", pet_id)
	_prev_pos = global_position
	if is_multiplayer_authority():
		camera.current = true
		camera.fov = Graphics.camera_fov
		Graphics.changed.connect(_on_graphics_changed)
		model_root.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		camera.queue_free()
		name_label = Label3D.new()
		name_label.text = str(GameNet.players.get(str(name).to_int(), {}).get("name", "Player"))
		name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		name_label.no_depth_test = true
		name_label.font_size = 40
		name_label.pixel_size = 0.004
		name_label.position = Vector3(0, 1.25, 0)
		add_child(name_label)


# The sight bubble lives low on the body (not at head height) so it actually lights the floor and walls around you.
func _on_graphics_changed() -> void:
	if camera != null:
		camera.fov = Graphics.camera_fov


func _setup_lights() -> void:
	guide_light.reparent(self, false)
	guide_light.position = Vector3(0, SIGHT_HEIGHT - 0.9, 0)
	guide_light.omni_range = SIGHT_RANGE
	guide_light.light_energy = SIGHT_ENERGY
	guide_light.omni_attenuation = SIGHT_ATTENUATION
	guide_light.light_specular = 0.0
	guide_light.shadow_enabled = false
	flashlight.spot_range = FLASH_RANGE
	flashlight.light_energy = FLASH_ENERGY
	flashlight.spot_angle = FLASH_ANGLE
	flashlight.spot_attenuation = 0.7
	flashlight.shadow_enabled = false


func set_role(p_role: String) -> void:
	role = p_role
	is_carrier = (role == "carrier")
	if is_inside_tree():
		_apply_role()


func _apply_role() -> void:
	flashlight.visible = is_carrier
	guide_light.visible = (role == "guide")
	if is_multiplayer_authority() and camera != null and is_instance_valid(camera):
		# Blind: draws only layer 20 (the white outlines). Everyone else: everything except layer 20.
		if is_carrier:
			camera.cull_mask = AS.OUTLINE_LAYER
		else:
			camera.cull_mask = 0xFFFFF & ~AS.OUTLINE_LAYER
	# Blind player's Echo Ping (Q) + private sounds
	if is_multiplayer_authority() and is_carrier:
		if _senses == null or not is_instance_valid(_senses):
			_senses = preload("res://blind_senses.gd").new()
			_senses.setup(self)
			add_child(_senses)
	elif _senses != null and is_instance_valid(_senses):
		_senses.queue_free()
		_senses = null


# ---------------------------------------------------------------- model

func _rebuild_model() -> void:
	for c in model_root.get_children():
		c.queue_free()
	anim = null
	_cur_clip = ""
	_is_moving_anim = false
	_one_shot_t = 0.0
	var m := AS.make_character(skin_idx, STAND_HEIGHT)
	if m != null:
		m.rotation.y = MODEL_YAW
		m.position = Vector3(0, -STAND_HEIGHT / 2.0, 0)
		model_root.add_child(m)
		anim = AS.find_anim_player(m)
		if anim != null:
			_walk_name = AS.anim_name(anim, "Walk")
			_run_name = AS.anim_name(anim, "Run")
			_idle_name = AS.anim_name(anim, "Idle")
			_sneak_name = AS.anim_name(anim, "Sneak")
			if _sneak_name == "":
				_sneak_name = AS.anim_name(anim, "Crouch")
			if _sneak_name == _walk_name:
				_sneak_name = ""
			_attack_name = AS.anim_name(anim, "Attack")
			_hit_name = AS.anim_name(anim, "RecieveHit")
			if _hit_name == "":
				_hit_name = AS.anim_name(anim, "Hit")
			_death_name = AS.anim_name(anim, "Death")
			AS.set_loop(anim, _walk_name)
			AS.set_loop(anim, _run_name)
			AS.set_loop(anim, _idle_name)
			AS.set_loop(anim, _sneak_name)
			# Blend times per pair: slow on the way to idle so the legs ease out instead of snapping.
			anim.playback_default_blend_time = 0.25
			var clips := [_walk_name, _run_name, _sneak_name, _idle_name, _attack_name, _hit_name, _death_name]
			for a in clips:
				for b in clips:
					if a != "" and b != "" and a != b:
						anim.set_blend_time(a, b, 0.35 if b == _idle_name else 0.2)
			if _idle_name != "":
				anim.play(_idle_name)
				_cur_clip = _idle_name
	else:
		# no model: coloured capsule
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.35
		cm.height = STAND_HEIGHT
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.from_hsv(float(str(name).to_int() % 7) / 7.0, 0.5, 0.9)
		cm.material = mat
		mi.mesh = cm
		model_root.add_child(mi)
	_last_skin = skin_idx


# ---------------------------------------------------------------- pet
# The pet is a separate node (not a child) that walks after the owner and plays Idle / Walk.
const PET_YAW := PI
var pet_id := ""
var _pet: Node3D = null
var _pet_anim: AnimationPlayer = null
var _pet_walk := ""
var _pet_idle := ""
var _pet_moving := false
var _pet_yaw := 0.0


func set_pet(id: String) -> void:
	pet_id = id
	if _pet != null and is_instance_valid(_pet):
		_pet.queue_free()
	_pet = null
	_pet_anim = null
	var d := AS.pet_def(id)
	if d.is_empty() or not is_inside_tree():
		return
	var m := AS.instance_fitted(d["file"], float(d["height"]))
	if m == null:
		push_warning("[PET] model not found: " + str(d["file"]))
		return
	var holder := Node3D.new()
	holder.name = "Pet_" + str(name)
	m.rotation.y = PET_YAW
	holder.add_child(m)
	get_parent().get_parent().add_child(holder)   # not under Players (it counts players)
	holder.global_position = global_position + Vector3(1.0, -0.9, 0.8)
	_pet = holder
	_pet_anim = AS.find_anim_player(m)
	if _pet_anim != null:
		_pet_walk = AS.anim_name(_pet_anim, "Walk")
		_pet_idle = AS.anim_name(_pet_anim, "Idle")
		AS.set_loop(_pet_anim, _pet_walk)
		AS.set_loop(_pet_anim, _pet_idle)
		_pet_anim.playback_default_blend_time = 0.25
		if _pet_idle != "":
			_pet_anim.play(_pet_idle)


func _update_pet(delta: float) -> void:
	if _pet == null or not is_instance_valid(_pet):
		return
	var feet := global_position.y - 0.9
	var want := global_position + global_transform.basis * Vector3(0.9, 0, 0.9)
	want.y = feet
	var cur := _pet.global_position
	var flat := Vector2(want.x - cur.x, want.z - cur.z)
	if flat.length() > 7.0:
		_pet.global_position = want          # teleport (portal / respawn)
		return
	var moving_now := flat.length() > 0.55
	if moving_now:
		var step := minf(flat.length(), 3.4 * delta)
		var dir := flat.normalized()
		cur.x += dir.x * step
		cur.z += dir.y * step
		_pet_yaw = lerp_angle(_pet_yaw, atan2(dir.x, dir.y), clampf(10.0 * delta, 0.0, 1.0))
	cur.y = lerpf(cur.y, feet, clampf(12.0 * delta, 0.0, 1.0))
	_pet.global_position = cur
	_pet.rotation.y = _pet_yaw
	if moving_now != _pet_moving and _pet_anim != null:
		_pet_moving = moving_now
		var clip := _pet_walk if moving_now else _pet_idle
		if clip != "":
			_pet_anim.play(clip)


func _exit_tree() -> void:
	if _pet != null and is_instance_valid(_pet):
		_pet.queue_free()


# Shift: sprint while the light-blue bar lasts (20 s). Release -> refills in 10 s, locked until full.
func _sprint_tick(delta: float, can_move: bool) -> void:
	var held := can_move and Input.is_key_pressed(KEY_SHIFT) and not crouching
	var was := sprinting
	sprinting = held and not sprint_locked and sprint_energy > 0.0
	if sprinting:
		sprint_energy = maxf(0.0, sprint_energy - delta / SPRINT_TIME)
		if sprint_energy <= 0.0:
			sprinting = false
			sprint_locked = true
	else:
		if was or (held and sprint_energy <= 0.0):
			sprint_locked = true                      # key released (or bar empty): wait for a full refill
		if not held or sprint_locked:
			sprint_energy = minf(1.0, sprint_energy + delta / SPRINT_REFILL)
		if sprint_locked and sprint_energy >= 1.0:
			sprint_locked = false
	sprint_changed.emit(sprint_energy, sprint_locked)


# thrown by the duck towards the lava
func launch(v: Vector3) -> void:
	grabbed_by = null
	velocity.y = v.y
	_launch_v = v
	_launch_t = 0.9


# ---------------------------------------------------------------- footsteps (3D sound on the Footsteps bus)
func _foot_tick() -> void:
	if _foot == null:
		var s: AudioStream = Sfx.stream("foot")
		if s == null:
			return
		if s is AudioStreamMP3:
			(s as AudioStreamMP3).loop = true
		_foot = AudioStreamPlayer3D.new()
		_foot.stream = s
		_foot.bus = "Footsteps"
		_foot.unit_size = 8.0
		_foot.max_distance = 40.0
		_foot.position = Vector3(0, -0.8, 0)
		add_child(_foot)
	var walking := false
	if is_multiplayer_authority():
		walking = moving and is_on_floor() and grabbed_by == null
	else:
		walking = _remote_speed > 0.8
	if walking:
		_foot.volume_db = -14.0 if crouching else -4.0
		var running := sprinting if is_multiplayer_authority() else _remote_speed > WALK_SPEED * 1.15
		_foot.pitch_scale = 1.28 if running else 1.0
		if not _foot.playing:
			_foot.play()
	elif _foot.playing:
		_foot.stop()


# ---------------------------------------------------------------- sword (Cave 5, sighted players)
func set_sword(on: bool) -> void:
	if not is_multiplayer_authority() or camera == null or not is_instance_valid(camera):
		return
	on = on and not is_carrier
	has_sword = on
	if _sword != null and is_instance_valid(_sword):
		_sword.queue_free()
	_sword = null
	if not on:
		return
	var m := AS.instance_fitted("Warrior_Sword.fbx", 0.8, true)
	if m == null:
		has_sword = true            # still hits, just no model
		return
	AS.apply_texture(m, AS.load_texture("Warrior_Sword_Texture.png"))
	camera.add_child(m)
	m.position = Vector3(0.38, -0.4, -0.75)
	m.rotation_degrees = Vector3(-15, 0, 25)
	_sword = m


func swing() -> void:
	var n: Node3D = _sword if _sword != null else null
	if n == null or not is_instance_valid(n):
		return
	rpc_attack_anim.rpc()
	var t := create_tween()
	t.tween_property(n, "rotation_degrees:x", -75.0, 0.08)
	t.tween_property(n, "rotation_degrees:x", -15.0, 0.18)


func set_skin(idx: int) -> void:
	skin_idx = idx
	if is_inside_tree():
		_rebuild_model()
		if is_multiplayer_authority():
			model_root.visible = false


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not frozen and not ui_open:
		rotate_y(-event.relative.x * Graphics.mouse_sensitivity)
		head.rotate_x(-event.relative.y * Graphics.mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not ui_open:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not ui_open:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED       # first click only re-captures the mouse
		elif not frozen:
			primary_action.emit()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F and is_carrier and not ui_open:
		flashlight_on = not flashlight_on
		flashlight.visible = flashlight_on
	elif event.is_action_pressed("throw") and not ui_open and not frozen:
		if stones > 0:
			stones -= 1
			var dir := -camera.global_transform.basis.z
			throw_requested.emit(camera.global_position + dir * 0.6, dir)


# Ray from the centre of the screen (the crosshair dot). Returns the intersect_ray dictionary or {}.
func look_ray(max_dist: float, mask: int) -> Dictionary:
	if camera == null or not is_instance_valid(camera) or not is_inside_tree():
		return {}
	var from := camera.global_position
	var to := from + (-camera.global_transform.basis.z) * max_dist
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.exclude = [get_rid()]
	q.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(q)


@rpc("any_peer", "call_local", "reliable")
func rpc_ping_noise() -> void:
	ping_noise_t = 2.0


func get_noise_radius() -> float:
	if ping_noise_t > 0.0:
		return 16.0
	if not moving:
		return 1.0
	if crouching:
		return 3.0
	return 20.0 if sprinting else 13.0


# ---------------------------------------------------------------- movement

func _physics_process(delta: float) -> void:
	ping_noise_t = maxf(0.0, ping_noise_t - delta)
	if is_multiplayer_authority():
		_local_tick(delta)
	else:
		_remote_tick(delta)
	_update_pet(delta)
	_foot_tick()
	_update_height(delta)
	_update_anim(delta)
	_prev_pos = global_position


func _local_tick(delta: float) -> void:
	if grabbed_by != null:
		if not is_instance_valid(grabbed_by) or grabbed_by.grabbed_id != str(name).to_int():
			grabbed_by = null
		else:
			velocity = Vector3.ZERO
			global_position = grabbed_by.mouth_pos() - Vector3(0, 0.2, 0)
			moving = false
			if sync_enabled and GameNet.has_other_peers():
				_sync_state.rpc(global_position, rotation.y, head.rotation.x, moving, crouching, flashlight_on, skin_idx, pet_id)
			return
	if not is_on_floor():
		velocity += get_gravity() * delta
	var can_move := not frozen and not ui_open
	crouching = can_move and Input.is_action_pressed("crouch")
	var dir := Vector3.ZERO
	if can_move:
		var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		dir = (transform.basis * Vector3(inp.x, 0, inp.y)).normalized()
		if Input.is_action_just_pressed("jump") and is_on_floor() and not crouching:
			velocity.y = JUMP_VELOCITY
	var base := CROUCH_SPEED if crouching else WALK_SPEED
	var hurt_factor := lerpf(0.5, 1.0, clampf(hp / MAX_HP, 0.0, 1.0))
	var speed := base * hurt_factor
	_sprint_tick(delta, can_move)
	if sprinting:
		speed *= SPRINT_MULT
	if dir != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, dir.x * speed, speed * ACCEL * delta)
		velocity.z = move_toward(velocity.z, dir.z * speed, speed * ACCEL * delta)
	else:
		# decelerate relative to the walk speed so the stop takes the same time crouched or not
		velocity.x = move_toward(velocity.x, 0.0, WALK_SPEED * DECEL * delta)
		velocity.z = move_toward(velocity.z, 0.0, WALK_SPEED * DECEL * delta)
	if _launch_t > 0.0:
		_launch_t -= delta
		velocity.x = _launch_v.x
		velocity.z = _launch_v.z
	move_and_slide()
	moving = Vector2(velocity.x, velocity.z).length() > 0.4 and can_move
	if sync_enabled and GameNet.has_other_peers():
		_sync_state.rpc(global_position, rotation.y, head.rotation.x, moving, crouching, flashlight_on, skin_idx, pet_id)


func _remote_tick(delta: float) -> void:
	if not _has_state:
		return
	var k := clampf(REMOTE_LERP * delta, 0.0, 1.0)
	if global_position.distance_to(_target_pos) > 6.0:
		global_position = _target_pos       # instant teleport (respawn / portal)
		_prev_pos = global_position
	global_position = global_position.lerp(_target_pos, k)
	rotation.y = lerp_angle(rotation.y, _target_yaw, k)
	head.rotation.x = lerpf(head.rotation.x, _target_pitch, k)
	# the speed we actually SEE on screen (smooth), used to drive the leg animation of remote players
	var seen := Vector2(global_position.x - _prev_pos.x, global_position.z - _prev_pos.z).length() / maxf(delta, 0.0001)
	_remote_speed = lerpf(_remote_speed, seen, clampf(10.0 * delta, 0.0, 1.0))


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_state(pos: Vector3, yaw: float, pitch: float, p_moving: bool, p_crouch: bool, p_flash: bool, p_skin: int, p_pet: String = "") -> void:
	if not _has_state:
		global_position = pos
		_prev_pos = pos
		_has_state = true
	_target_pos = pos
	_target_yaw = yaw
	_target_pitch = pitch
	moving = p_moving
	crouching = p_crouch
	flashlight_on = p_flash
	if is_carrier:
		flashlight.visible = p_flash
	if p_skin != skin_idx:
		set_skin(p_skin)
	if p_pet != pet_id:
		set_pet(p_pet)


# capsule height and camera change smoothly when crouching
func _update_height(delta: float) -> void:
	var want := CROUCH_HEIGHT if crouching else STAND_HEIGHT
	_height_cur = lerpf(_height_cur, want, clampf(10.0 * delta, 0.0, 1.0))
	_shape.height = _height_cur
	col.position.y = (_height_cur - STAND_HEIGHT) / 2.0
	head.position.y = _height_cur - 1.1
	var s := _height_cur / STAND_HEIGHT
	model_root.scale = Vector3(1, s, 1)
	model_root.position.y = -0.9 * (1.0 - s)


# ---------------------------------------------------------------- animation
# Fixes for the "feet snap when you stop":
#  1. the animation speed follows the REAL speed (so the legs slow down while you decelerate),
#  2. idle <-> walk uses hysteresis (no flicker) and long blends towards idle,
#  3. crouch-walk uses the same clip slowed down by the real speed (no restart when you press Ctrl),
#  4. remote players are driven by the speed seen on screen, not by a network flag.

func _play_one_shot(clip: String, blend := 0.1) -> void:
	if anim == null or clip == "" or not is_inside_tree():
		return
	var a := anim.get_animation(clip)
	if a == null:
		return
	_one_shot_t = maxf(0.15, a.length)
	_cur_clip = clip
	anim.speed_scale = 1.0
	anim.play(clip, blend)


func play_attack() -> void:
	_play_one_shot(_attack_name, 0.08)


func play_hit() -> void:
	_play_one_shot(_hit_name, 0.06)


func play_death() -> void:
	_play_one_shot(_death_name, 0.12)


# Peer-visible actions (the local body is hidden in first person, so only remote models show these).
@rpc("any_peer", "call_local", "unreliable")
func rpc_attack_anim() -> void:
	play_attack()


@rpc("any_peer", "call_local", "unreliable")
func rpc_hit_anim() -> void:
	play_hit()


func _update_anim(delta: float) -> void:
	if anim == null:
		return
	if _one_shot_t > 0.0:
		_one_shot_t -= delta
		if _one_shot_t > 0.0:
			return
		_cur_clip = ""
	var spd := 0.0
	if is_multiplayer_authority():
		spd = Vector2(velocity.x, velocity.z).length()
	else:
		spd = _remote_speed
	_speed_smooth = lerpf(_speed_smooth, spd, clampf(14.0 * delta, 0.0, 1.0))
	if _is_moving_anim:
		if _speed_smooth < 0.3:
			_is_moving_anim = false
	else:
		if _speed_smooth > 0.65:
			_is_moving_anim = true
	var clip := _idle_name
	if _is_moving_anim:
		clip = _walk_name
		if crouching and _sneak_name != "":
			clip = _sneak_name
		elif _run_name != "" and _speed_smooth > WALK_SPEED * 1.15:
			clip = _run_name
	if clip != "" and clip != _cur_clip:
		_cur_clip = clip
		anim.play(clip)                    # blend time comes from set_blend_time()
	if _is_moving_anim and _cur_clip != _idle_name:
		# stride matched to the real speed: legs never slide on the floor
		var ref := WALK_SPEED
		if _cur_clip == _run_name:
			ref = WALK_SPEED * SPRINT_MULT
		anim.speed_scale = clampf(_speed_smooth / ref, 0.4, 1.35)
	else:
		anim.speed_scale = 1.0


# ---------------------------------------------------------------- damage and death

@rpc("any_peer", "call_local", "reliable")
func rpc_damage(amount: float) -> void:
	if not is_multiplayer_authority() or frozen:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	hp = maxf(0.0, hp - amount)
	hp_changed.emit(hp)
	if amount > 0.0:
		rpc_hit_anim.rpc()
	if hp <= 0.0:
		died.emit()


func heal_full() -> void:
	hp = MAX_HP
	hp_changed.emit(hp)


func respawn(pos: Vector3, yaw: float = 0.0) -> void:
	global_position = pos
	_prev_pos = pos
	velocity = Vector3.ZERO
	rotation.y = yaw
	head.rotation.x = 0.0
	_has_state = false
	_speed_smooth = 0.0
	_remote_speed = 0.0
	heal_full()
