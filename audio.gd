extends Node
# Audio manager (autoload "Sfx"): buses Music / SFX / Footsteps / Monsters, one-shot sounds,
# looping music and "play, wait until finished + gap, play again" loops for the monsters.
const AS := preload("res://assets.gd")

const BUSES := ["Music", "SFX", "Footsteps", "Monsters"]
const SAVE := "user://audio.json"
# key -> [file name, bus]
const SOUNDS := {
	"music": ["simplesound-horror-trailer-443327.mp3", "Music"],
	"foot": ["dragon-studio-footsteps-on-wood-397989.mp3", "Footsteps"],
	"scare": ["magiaz-scare-407344.mp3", "SFX"],
	"rock": ["u_xjrmmgxfru-hit-rock-02-266304.mp3", "SFX"],
	"vase": ["freesound_community-breaking-a-vase-remix-87091.mp3", "SFX"],
	"punch": ["universfield-punch-140236.mp3", "SFX"],
	"howl": ["dragon-studio-wolf-howl-2-359870.mp3", "Monsters"],
	"witch": ["alex_jauk-evil-witch-laughing-sound-440272.mp3", "SFX"],
	"quack": ["freesound_community-duck-quacking-37392.mp3", "Monsters"],
	"roar": ["freesound_community-monster-roar-6985.mp3", "Monsters"],
}

var _streams := {}
var _warned := {}
var _gen := {}
var _music: AudioStreamPlayer


func _ready() -> void:
	for b in BUSES:
		if AudioServer.get_bus_index(b) == -1:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")
	_load_volumes()


func stream(key: String) -> AudioStream:
	if _streams.has(key):
		return _streams[key]
	var path := AS.find(SOUNDS[key][0])
	var s: AudioStream = null
	if path != "":
		s = load(path) as AudioStream
	if s == null and not _warned.has(key):
		_warned[key] = true
		push_warning("[AUDIO] missing sound: " + str(SOUNDS[key][0]))
		print("[AUDIO] MISSING: ", SOUNDS[key][0])
	_streams[key] = s
	return s


# pos = Vector3.INF -> plain 2D sound for everybody, otherwise positional 3D sound
func play(key: String, pos: Vector3 = Vector3.INF, vol_db: float = 0.0) -> Node:
	var s := stream(key)
	if s == null:
		return null
	var p: Node
	if pos == Vector3.INF:
		var a := AudioStreamPlayer.new()
		a.stream = s
		a.bus = SOUNDS[key][1]
		a.volume_db = vol_db
		add_child(a)
		a.play()
		a.finished.connect(a.queue_free)
		p = a
	else:
		var a3 := AudioStreamPlayer3D.new()
		a3.stream = s
		a3.bus = SOUNDS[key][1]
		a3.volume_db = vol_db
		a3.unit_size = 14.0
		a3.max_distance = 80.0
		add_child(a3)
		a3.global_position = pos
		a3.play()
		a3.finished.connect(a3.queue_free)
		p = a3
	return p


func play_music() -> void:
	if _music != null and _music.playing:
		return
	var s := stream("music")
	if s == null:
		return
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	_music = AudioStreamPlayer.new()
	_music.stream = s
	_music.bus = "Music"
	_music.volume_db = -6.0
	add_child(_music)
	_music.play()


# play -> wait until it has finished + gap seconds -> play again, while active.call() is true
func loop_gap(key: String, gap: float, active: Callable) -> void:
	var g: int = int(_gen.get(key, 0)) + 1
	_gen[key] = g
	while active.call() and int(_gen.get(key, 0)) == g:
		var p = play(key)
		if p == null:
			return
		await (p as Node).tree_exited
		if not active.call() or int(_gen.get(key, 0)) != g:
			return
		await get_tree().create_timer(gap).timeout


func stop_loop(key: String) -> void:
	_gen[key] = int(_gen.get(key, 0)) + 1


# ---- volumes (0..1) ----
func set_volume(bus: String, v: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, v <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.0001)))
	_save_volumes()


func get_volume(bus: String) -> float:
	var i := AudioServer.get_bus_index(bus)
	if i < 0 or AudioServer.is_bus_mute(i):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(i))


func _save_volumes() -> void:
	var d := {}
	for b in ["Master"] + BUSES:
		d[b] = get_volume(b)
	var f := FileAccess.open(SAVE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))


func _load_volumes() -> void:
	if not FileAccess.file_exists(SAVE):
		return
	var f := FileAccess.open(SAVE, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text()) if f != null else null
	if data is Dictionary:
		for b in data.keys():
			var i := AudioServer.get_bus_index(str(b))
			if i >= 0:
				var v := float(data[b])
				AudioServer.set_bus_mute(i, v <= 0.001)
				AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.0001)))
