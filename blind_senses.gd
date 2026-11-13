extends Node
# Blind player's senses (created by player.gd, only on the machine of the BLIND player):
#  1) ECHO PING  (Q): a white wave runs over the walls / objects around you for ~2.5 s. Cooldown 8 s.
#     The sound of the ping also makes monsters hear you (player.ping_noise_t).
#  2) PRIVATE SOUNDS only the blind player hears:
#     - heartbeat that speeds up as a monster gets closer
#     - 3D growl from the monster's position
#     - coin jingle coming from loot (bags / coins / pots / chests) near him

const AS := preload("res://assets.gd")

const PING_KEY := KEY_Q
const PING_COOLDOWN := 8.0
const PING_RADIUS := 18.0
const PING_TIME := 2.5
const PING_MAX_MESHES := 160
const HEART_RANGE := 22.0
const GROWL_RANGE := 30.0
const JINGLE_RANGE := 12.0

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform vec3 origin = vec3(0.0);
uniform float radius = 0.0;
uniform float fade = 1.0;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float d = distance(wpos, origin);
	float band = 1.0 - smoothstep(0.0, 1.6, abs(d - radius));          // bright wavefront
	float tail = (d < radius) ? 0.35 : 0.0;                             // dim glow behind the wave
	float k = clamp(band + tail, 0.0, 1.0) * fade;
	ALBEDO = vec3(1.0) * k;
}
"""

var player: Node3D
var _cd := 0.0
var _wave_t := -1.0
var _origin := Vector3.ZERO
var _mat: ShaderMaterial
var _holder: Node3D
var _heart: AudioStreamPlayer
var _heart_t := 0.0
var _jingle_t := 0.0
var _growl_t := 0.0
var _snd_ping: AudioStreamWAV
var _snd_beat: AudioStreamWAV
var _snd_coin: AudioStreamWAV
var _label: Label
var _world: Node = null


func setup(p: Node3D) -> void:
	player = p


func _ready() -> void:
	_snd_ping = _tone(740.0, 1.1, 0.5, 1.8)
	_snd_beat = _tone(55.0, 0.22, 0.9, 6.0)
	_snd_coin = _tone(2300.0, 0.35, 0.35, 5.0)
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat.shader = sh
	_holder = Node3D.new()
	add_child(_holder)
	_heart = AudioStreamPlayer.new()
	_heart.stream = _snd_beat
	_heart.bus = "SFX"
	add_child(_heart)
	var cl := CanvasLayer.new()
	add_child(cl)
	_label = Label.new()
	_label.position = Vector2(24, 24)
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	cl.add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	if player == null or not is_instance_valid(player):
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == PING_KEY:
		if _cd <= 0.0 and not player.frozen and not player.ui_open:
			_ping()


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_cd = maxf(0.0, _cd - delta)
	if _cd <= 0.0:
		_label.text = "[Q] Echo Ping - READY"
	else:
		_label.text = "[Q] Echo Ping - %d s" % int(ceil(_cd))
	_label.visible = player.role == "carrier"
	if _wave_t >= 0.0:
		_wave_t += delta
		_mat.set_shader_parameter("radius", (_wave_t / PING_TIME) * (PING_RADIUS + 2.0))
		_mat.set_shader_parameter("fade", clampf(1.0 - (_wave_t / PING_TIME) * 0.9, 0.0, 1.0))
		if _wave_t >= PING_TIME:
			_wave_t = -1.0
			for c in _holder.get_children():
				c.queue_free()
	_senses_tick(delta)


# ---------------------------------------------------------------- echo ping
func _ping() -> void:
	_cd = PING_COOLDOWN
	_origin = player.global_position
	_mat.set_shader_parameter("origin", _origin)
	_mat.set_shader_parameter("radius", 0.0)
	_mat.set_shader_parameter("fade", 1.0)
	for c in _holder.get_children():
		c.queue_free()
	var found: Array = []
	_collect(get_tree().current_scene, found)
	found.sort_custom(func(a, b): return a[0] < b[0])
	var n := 0
	for it in found:
		if n >= PING_MAX_MESHES:
			break
		var src: MeshInstance3D = it[1]
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		mi.material_override = _mat
		mi.layers = AS.OUTLINE_LAYER
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_holder.add_child(mi)
		mi.global_transform = src.global_transform
		n += 1
	_wave_t = 0.0
	var a := AudioStreamPlayer.new()
	a.stream = _snd_ping
	a.bus = "SFX"
	a.volume_db = -4.0
	add_child(a)
	a.play()
	a.finished.connect(a.queue_free)
	# monsters hear the ping (everybody gets the rpc so the server can check it)
	player.rpc_ping_noise.rpc()


func _collect(node: Node, out: Array) -> void:
	if node == player or node == _holder or node.is_in_group("players"):
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh != null and mi.layers & 1 != 0 and mi.is_visible_in_tree():
			var ab := mi.global_transform * mi.get_aabb()
			var c := ab.get_center()
			var d := maxf(0.0, c.distance_to(_origin) - ab.size.length() * 0.5)
			if d <= PING_RADIUS:
				out.append([d, mi])
	for ch in node.get_children():
		_collect(ch, out)


# ---------------------------------------------------------------- private sounds
func _senses_tick(delta: float) -> void:
	if player.role != "carrier" or player.frozen:
		_heart.stop()
		return
	if _world == null or not is_instance_valid(_world):
		_world = get_tree().get_first_node_in_group("world")
	if _world == null:
		return
	# heartbeat + growl: nearest active monster
	var near := 999.0
	var near_pos := Vector3.ZERO
	var near_kind := "howl"
	var creatures = _world.get("creatures")
	if creatures is Dictionary:
		for k in creatures.keys():
			var c = creatures[k]
			if c != null and is_instance_valid(c) and c.get("active"):
				var d: float = c.global_position.distance_to(player.global_position)
				if d < near:
					near = d
					near_pos = c.global_position
					near_kind = "quack" if c.get("kind") == "duck" else "howl"
	_heart_t -= delta
	if near < HEART_RANGE and _heart_t <= 0.0:
		var closeness := 1.0 - near / HEART_RANGE
		_heart_t = lerpf(1.0, 0.35, closeness)
		_heart.volume_db = lerpf(-18.0, 0.0, closeness)
		_heart.play()
		get_tree().create_timer(0.18).timeout.connect(func(): if is_instance_valid(_heart): _heart.play())
	_growl_t -= delta
	if near < GROWL_RANGE and _growl_t <= 0.0:
		_growl_t = 5.0
		Sfx.play(near_kind, near_pos, 3.0)
	# loot jingle: nearest unbroken loot
	_jingle_t -= delta
	if _jingle_t <= 0.0:
		var loot = _world.get("loot")
		if loot is Dictionary:
			var best := 999.0
			var best_pos := Vector3.ZERO
			for id in loot.keys():
				var e: Dictionary = loot[id]
				if e.get("broken", false):
					continue
				var node = e.get("node")
				if node == null or not is_instance_valid(node):
					continue
				var d: float = node.global_position.distance_to(player.global_position)
				if d < best:
					best = d
					best_pos = node.global_position
			if best < JINGLE_RANGE:
				_jingle_t = lerpf(0.7, 2.2, best / JINGLE_RANGE)
				var a3 := AudioStreamPlayer3D.new()
				a3.stream = _snd_coin
				a3.bus = "SFX"
				a3.unit_size = 6.0
				a3.max_distance = JINGLE_RANGE + 4.0
				a3.volume_db = 2.0
				add_child(a3)
				a3.global_position = best_pos
				a3.play()
				a3.finished.connect(a3.queue_free)
			else:
				_jingle_t = 0.5


# simple generated tone (no audio files needed)
static func _tone(freq: float, dur: float, vol: float, decay: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t := float(i) / float(rate)
		var env := exp(-decay * t / dur)
		var s := (sin(TAU * freq * t) + 0.4 * sin(TAU * freq * 2.01 * t)) * env * vol * 0.7
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
