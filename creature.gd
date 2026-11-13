extends CharacterBody3D
# وحش (ذئب / بطة): الذكاء الاصطناعي بيشتغل عند الهوست بس، والباقي بياخدوا الموقع والأنيميشن.
# سمع عالي: اللاعب الماشي عادي بيتسمع من بعيد، المنحني (Crouch) بيتسمع من قريب جداً فقط.

const AS := preload("res://assets.gd")
const MODEL_YAW := PI          # لو الوحش ماشي بضهره غيّر القيمة دي لـ 0.0

enum State { PATROL, INVESTIGATE, CHASE }

var kind := "wolf"
var walk_speed := 2.0
var run_speed := 6.0
var hearing_mult := 1.6
var dmg_per_sec := 5.0
var attack_range := 1.5
var waypoints: Array[Vector3] = []
var active := false
var spawn_pos := Vector3.ZERO

var _state := State.PATROL
var _wp := 0
var _target_pos := Vector3.ZERO
var _chase_player: Node3D = null
var _wait := 0.0
var _lose_timer := 0.0
var _dmg_acc := 0.0
var _model: Node3D
var _anim: AnimationPlayer
var _anim_names := {}
var _cur_anim := ""
var _net_target := Vector3.ZERO
var _net_yaw := 0.0
var _has_net := false
var _anim_code := 0     # 0 idle 1 walk 2 run 3 lunge
const LUNGE_TIME := 0.38
var _lunge_t := 0.0
var _lunge_cd := 0.0
var _last_seen := Vector3.ZERO
var _skel: Skeleton3D
var _head_idx := -1
var _eyes: Node3D
var _eye_gap := 0.055
var _eye_fwd := 0.16
var _roar_cd := 0.0

# ---- duck only: grab / carry to the lava / stun ----
var grabbed_id := 0            # peer id of the carried player (0 = none), synced by rpc
var lava_pos := Vector3.ZERO
var has_lava := false
var stunned := false
var _stun_t := 0.0
var _grab_hits := 0
var _grab_cd := 0.0
var _stars: Array = []
var _star_t := 0.0
const STUN_HITS := 15
const STUN_TIME := 10.0


func setup(p_kind: String, model_part: String, height: float, p_walk: float, p_run: float, p_hear: float, p_dps: float, p_waypoints: Array[Vector3]) -> void:
	kind = p_kind
	walk_speed = p_walk
	run_speed = p_run
	hearing_mult = p_hear
	dmg_per_sec = p_dps
	waypoints = p_waypoints
	collision_layer = 2
	collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.0
	cs.shape = cap
	cs.position.y = 0.5
	add_child(cs)
	_model = AS.instance_fitted(model_part, height)
	if _model != null:
		_model.rotation.y = MODEL_YAW
		add_child(_model)
	_anim = AS.find_anim_player(_model)
	_skel = AS.find_skeleton(_model)
	if _skel != null:
		_head_idx = _skel.find_bone("Head")
		if _head_idx >= 0:
			_build_eyes()
	if _anim != null:
		for n in ["Idle", "Walk", "Run"]:
			_anim_names[n] = AS.anim_name(_anim, n)
			AS.set_loop(_anim, _anim_names[n])
		_anim.playback_default_blend_time = 0.25
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.7, 0.9, 1.4)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.3, 0.3, 0.32) if kind == "wolf" else Color(0.9, 0.8, 0.2)
		bm.material = m
		mi.mesh = bm
		mi.position.y = 0.45
		add_child(mi)
		_model = mi


func _build_eyes() -> void:
	_eyes = Node3D.new()
	_eyes.name = "Eyes"
	add_child(_eyes)
	var glow := Color(1.0, 0.16, 0.08) if kind == "wolf" else Color(1.0, 0.72, 0.10)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = glow.darkened(0.4)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = glow
	mat.emission_energy_multiplier = 8.0
	mat.no_depth_test = true
	mat.render_priority = 2
	var r := 0.032 if kind == "wolf" else 0.045
	_eye_gap = 0.045 if kind == "wolf" else 0.06
	_eye_fwd = 0.05 if kind == "wolf" else 0.08
	for sx in [-1.0, 1.0]:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 6
		sm.rings = 3
		mi.mesh = sm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(sx * _eye_gap, 0.0, 0.0)
		_eyes.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = glow
	l.light_energy = 0.7
	l.omni_range = 1.8
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.position = Vector3(0.0, 0.0, 0.08)
	_eyes.add_child(l)


func place(pos: Vector3) -> void:
	spawn_pos = pos
	global_position = pos
	_net_target = pos


func reset() -> void:
	global_position = spawn_pos
	velocity = Vector3.ZERO
	_state = State.PATROL
	_chase_player = null
	_wp = 0
	_wait = 0.0
	grabbed_id = 0
	_grab_hits = 0
	_grab_cd = 0.0
	stunned = false
	_lunge_t = 0.0
	_lunge_cd = 0.0
	_roar_cd = 0.0
	_last_seen = spawn_pos
	_clear_stars()


# --------------------------------------------------------------- ضجيج (حجر مثلاً) — الهوست فقط
func hear_noise(pos: Vector3, radius: float) -> void:
	if not multiplayer.is_server() or not active:
		return
	if _state == State.CHASE:
		return
	if global_position.distance_to(pos) <= radius * hearing_mult:
		_state = State.INVESTIGATE
		_target_pos = Vector3(pos.x, global_position.y, pos.z)
		_wait = 0.0


func _physics_process(delta: float) -> void:
	_lunge_cd = maxf(0.0, _lunge_cd - delta)
	_lunge_t = maxf(0.0, _lunge_t - delta)
	_roar_cd = maxf(0.0, _roar_cd - delta)
	if multiplayer.is_server():
		_server_tick(delta)
		if _lunge_t > 0.0:
			_anim_code = 3
		if GameNet.has_other_peers():
			_net_state.rpc(global_position, rotation.y, _anim_code)
	else:
		_client_tick(delta)
	_apply_anim()


func _server_tick(delta: float) -> void:
	if not active:
		velocity = Vector3.ZERO
		_anim_code = 0
		return
	if kind == "duck":
		_grab_cd = maxf(0.0, _grab_cd - delta)
		if stunned:
			_stun_t -= delta
			velocity.x = 0.0
			velocity.z = 0.0
			_anim_code = 0
			_gravity(delta)
			move_and_slide()
			if _stun_t <= 0.0:
				_rpc_stun.rpc(false)
			return
		if grabbed_id != 0:
			_carry_tick(delta)
			return
	_listen()
	var speed := 0.0
	var goal := global_position
	match _state:
		State.PATROL:
			if waypoints.is_empty():
				_anim_code = 0
				return
			if _wait > 0.0:
				_wait -= delta
				_anim_code = 0
				velocity.x = 0.0
				velocity.z = 0.0
				_gravity(delta)
				move_and_slide()
				return
			goal = waypoints[_wp]
			speed = walk_speed
			if _flat_dist(goal) < 1.0:
				_wp = (_wp + 1) % waypoints.size()
				_wait = randf_range(1.5, 4.0)
		State.INVESTIGATE:
			goal = _target_pos
			speed = run_speed
			if _flat_dist(goal) < 1.2:
				_wait = 3.0
				_state = State.PATROL
				_anim_code = 0
		State.CHASE:
			if _chase_player == null or not is_instance_valid(_chase_player):
				_state = State.INVESTIGATE
				_target_pos = _last_seen
				_chase_player = null
				_wait = 0.0
			else:
				goal = _chase_player.global_position
				_last_seen = goal
				speed = run_speed
				var d := _flat_dist(goal)
				if d < attack_range:
					speed = 0.0
					if kind == "duck" and _grab_cd <= 0.0 and grabbed_id == 0:
						_rpc_grab.rpc(str((_chase_player as Node).name).to_int())
					else:
						_hit(delta)
				var p = _chase_player
				var radius: float = p.get_noise_radius() * hearing_mult
				if d > radius + 6.0:
					_lose_timer += delta
					if _lose_timer > 3.0:
						_state = State.INVESTIGATE
						_target_pos = _last_seen
						_chase_player = null
						_wait = 0.0
				else:
					_lose_timer = 0.0
	var dir := goal - global_position
	dir.y = 0.0
	if dir.length() > 0.2 and speed > 0.0:
		dir = dir.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		var target_yaw := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(8.0 * delta, 0.0, 1.0))
		_anim_code = 2 if speed >= run_speed - 0.1 else 1
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		if _state == State.CHASE and _chase_player != null:
			var look := _chase_player.global_position - global_position
			rotation.y = lerp_angle(rotation.y, atan2(-look.x, -look.z), clampf(8.0 * delta, 0.0, 1.0))
		_anim_code = 0
	_gravity(delta)
	move_and_slide()


func _gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= 20.0 * delta
	else:
		velocity.y = 0.0


func _flat_dist(p: Vector3) -> float:
	return Vector2(global_position.x - p.x, global_position.z - p.z).length()


# بيسمع اللاعبين: الماشي عادي بيتسمع من بعيد، المنحني بيتسمع من قريب
func _listen() -> void:
	if _state == State.CHASE:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if p.frozen:
			continue
		var d: float = global_position.distance_to(p.global_position)
		var r: float = p.get_noise_radius() * hearing_mult
		if d <= r:
			_state = State.CHASE
			_chase_player = p
			_last_seen = p.global_position
			_lose_timer = 0.0
			if _roar_cd <= 0.0:
				_roar_cd = 8.0
				get_tree().call_group("world", "sfx_all", "roar")
			return


func _lunge() -> void:
	_lunge_t = LUNGE_TIME
	_lunge_cd = 1.2


func _hit(delta: float) -> void:
	if kind == "wolf" and _lunge_cd <= 0.0:
		_lunge()
	_dmg_acc += delta
	if kind == "wolf" and _dmg_acc >= 0.2:
		get_tree().call_group("world", "sfx_all", "scare")     # jump scare: only when the WOLF damages someone
	if _dmg_acc >= 0.2:
		var amount := dmg_per_sec * _dmg_acc
		_dmg_acc = 0.0
		var pid := str((_chase_player as Node).name).to_int()
		if pid == 1 or not GameNet.has_other_peers():
			_chase_player.rpc_damage(amount)
		else:
			_chase_player.rpc_damage.rpc_id(pid, amount)


# --------------------------------------------------------------- عند باقي اللاعبين

func _client_tick(delta: float) -> void:
	if not _has_net:
		return
	var k := clampf(12.0 * delta, 0.0, 1.0)
	global_position = global_position.lerp(_net_target, k)
	rotation.y = lerp_angle(rotation.y, _net_yaw, k)


@rpc("authority", "call_remote", "unreliable_ordered")
func _net_state(pos: Vector3, yaw: float, code: int) -> void:
	_net_target = pos
	_net_yaw = yaw
	if code == 3 and _anim_code != 3:
		_lunge_t = LUNGE_TIME
	_anim_code = code
	if not _has_net:
		global_position = pos
		_has_net = true


func _apply_anim() -> void:
	if _anim_code == 3:
		if _model != null:
			var k := 1.0 - clampf(_lunge_t / LUNGE_TIME, 0.0, 1.0)
			_model.position.z = -sin(k * PI) * 0.6
			_model.position.y = 0.0
			_model.rotation.x = sin(k * PI) * 0.18
		return
	if _model != null:
		_model.position.z = lerpf(_model.position.z, 0.0, 0.35)
		_model.position.y = lerpf(_model.position.y, 0.0, 0.35)
		_model.rotation.x = lerpf(_model.rotation.x, 0.0, 0.35)
	if _anim == null:
		return
	var key: String = ["Idle", "Walk", "Run"][_anim_code]
	var nm: String = _anim_names.get(key, "")
	if nm != "" and nm != _cur_anim:
		_cur_anim = nm
		_anim.play(nm)


# ---------------------------------------------------------------- duck: grab / carry / stun
func mouth_pos() -> Vector3:
	return global_position + Vector3(0, 1.5, 0) + (-global_transform.basis.z) * 0.9


func _find_player(pid: int) -> Node3D:
	for p in get_tree().get_nodes_in_group("players"):
		if str(p.name).to_int() == pid:
			return p
	return null


# host: walk slowly to the lava with the player in the beak, keep biting, throw him in
func _carry_tick(delta: float) -> void:
	var p := _find_player(grabbed_id)
	if p == null:
		_rpc_release.rpc(grabbed_id, false)
		return
	_chase_player = p
	_hit(delta)
	var dir := Vector3.ZERO
	if has_lava:
		dir = lava_pos - global_position
		dir.y = 0.0
	if not has_lava or dir.length() < 3.2:
		_rpc_release.rpc(grabbed_id, true)
		return
	dir = dir.normalized()
	velocity.x = dir.x * walk_speed * 0.55
	velocity.z = dir.z * walk_speed * 0.55
	rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), clampf(6.0 * delta, 0.0, 1.0))
	_anim_code = 1
	_gravity(delta)
	move_and_slide()


@rpc("authority", "call_local", "reliable")
func _rpc_grab(pid: int) -> void:
	grabbed_id = pid
	_grab_hits = 0
	_lunge_t = LUNGE_TIME
	var p := _find_player(pid)
	if p != null and p.is_multiplayer_authority():
		p.grabbed_by = self
	Sfx.play("roar")


@rpc("authority", "call_local", "reliable")
func _rpc_release(pid: int, throw: bool) -> void:
	grabbed_id = 0
	_grab_cd = 4.0
	_grab_hits = 0
	var p := _find_player(pid)
	if p != null and p.is_multiplayer_authority():
		p.grabbed_by = null
		if throw and has_lava:
			_lunge_t = LUNGE_TIME
			var d := lava_pos - p.global_position
			d.y = 0.0
			p.launch(d.normalized() * 7.0 + Vector3(0, 4.0, 0))


# host: a sword hit counts only while the duck holds somebody
func sword_hit() -> void:
	if not multiplayer.is_server() or grabbed_id == 0 or stunned:
		return
	_grab_hits += 1
	get_tree().call_group("world", "sfx_all", "punch")
	if _grab_hits >= STUN_HITS:
		_rpc_release.rpc(grabbed_id, false)
		_stun_t = STUN_TIME
		_rpc_stun.rpc(true)


@rpc("authority", "call_local", "reliable")
func _rpc_stun(on: bool) -> void:
	stunned = on
	_clear_stars()
	if on:
		for i in range(3):
			var s := AS.instance_fitted("duck-base", 0.3)
			if s == null:
				var mi := MeshInstance3D.new()
				var sm := SphereMesh.new()
				sm.radius = 0.08
				sm.height = 0.16
				mi.mesh = sm
				s = Node3D.new()
				s.add_child(mi)
			add_child(s)
			_stars.append(s)


func _clear_stars() -> void:
	for s in _stars:
		if is_instance_valid(s):
			s.queue_free()
	_stars.clear()


func _update_eyes() -> void:
	if _eyes == null or _skel == null or _head_idx < 0:
		return
	_eyes.visible = active
	if not active:
		return
	var head := _skel.global_transform * _skel.get_bone_global_pose(_head_idx).origin
	var fwd := -global_transform.basis.z
	_eyes.global_position = head + fwd * _eye_fwd + Vector3.UP * 0.03
	_eyes.look_at(_eyes.global_position + fwd, Vector3.UP)


func _process(delta: float) -> void:
	_update_eyes()
	if _stars.is_empty():
		return
	_star_t += delta
	for i in range(_stars.size()):
		var a := _star_t * 3.0 + TAU * float(i) / 3.0
		var s: Node3D = _stars[i]
		if is_instance_valid(s):
			s.position = Vector3(cos(a) * 0.7, 2.15, sin(a) * 0.7)
			s.rotation.y = -a
