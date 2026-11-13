@tool
extends Node3D
# The whole game in ONE scene: lobby + 5 caves connected by doors. The host runs the game logic.
# Every peer builds the SAME level from the same seed (only the seeded rng is used while building),
# so loot ids, bookcase positions, vase hiding spots... are identical on all machines.

const AS := preload("res://assets.gd")
const LB := preload("res://level_builder.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const CREATURE := preload("res://creature.gd")
const HUD := preload("res://hud.gd")

# ---------------------------------------------------------------- constants
const LOBBY_SPAWN := Vector3(0, 1.0, 8)
const CAVE_START := {
	1: Vector3(0, 1.0, -34),
	2: Vector3(0, 1.0, -74),
	3: Vector3(0, 1.0, -124),
	4: Vector3(0, 1.0, -194),
	5: Vector3(0, 1.0, -264),
}
const DOOR_Z := {1: -70.0, 2: -120.0, 3: -190.0, 4: -260.0}
const GEN_TIME := 4.0                # seconds every generator must be held, all together
const COUNT_TIME := 30.0
const FALL_Y := -6.0

# Cave 3: 4 corridors (2 left, 2 right), one generator at the end of each
const GEN_COUNT := 4
const GEN_ALLOW_FEWER_PLAYERS := false   # true: with < 4 players the number of players is enough (testing). false: always need all 4.
const CORRIDOR_END := 22.0              # x of the end wall of every corridor
const CORRIDOR_ZS := [-142.0, -168.0]   # z centre of the two corridors on each side

# Loot
const LOOT_LAYER := 8
const LOOT_REACH := 3.0
const HIT_COOLDOWN := 0.28
const LOOT_PER_BOOKCASE := 2
const BOOKCASE_H := 2.4
const BOOKCASE_SCALE := 2.4 / 2.63       # fitted height / raw model height
# Free spots on the bookcase shelves (measured from the model): [x (raw), shelf index, height of the books under the item (raw)]
const SHELF_FLOOR := [0.16, 0.76, 1.37, 1.97]
const SHELF_SLOTS := [
	[-0.75, 1, 0.0], [-0.5, 1, 0.0], [-0.25, 1, 0.0],
	[-0.55, 0, 0.13], [0.25, 0, 0.19],
	[0.7, 3, 0.12], [-0.2, 3, 0.18],
	[-0.65, 2, 0.0], [0.3, 2, 0.0],
]
# kind -> model, size, collision box, hit points, coins when collected (bag / pile)
const LOOT_DEF := {
	"bag": {"file": "Bag_Coins.fbx", "fit": 0.5, "longest": true, "solid": false, "box": Vector3(0.7, 0.4, 0.7), "hp": 1, "coins": 25},
	"pile": {"file": "Coin_Pile.fbx", "fit": 0.36, "longest": true, "solid": false, "box": Vector3(0.6, 0.4, 0.6), "hp": 1, "coins": 15},
	"pot": {"file": "Pot1.fbx", "fit": 0.9, "longest": false, "solid": true, "box": Vector3(0.7, 0.9, 0.7), "hp": 8, "coins": 0},
	"chest": {"file": "Chest_Gold.fbx", "fit": 0.9, "longest": false, "solid": true, "box": Vector3(1.25, 0.9, 1.0), "hp": 10, "coins": 0},
}
const POT_BROKEN_AT := 4           # hp <= 4 -> broken model (4 hits intact + 4 hits broken)
const POT_DROP_COINS := 7          # 3 piles x 7  = 21 coins per vase
const CHEST_DROP_COINS := 10       # 3 piles x 10 = 30 coins per chest

# Assets the game needs. Anything missing is printed in the Output panel AND shown on screen.
const REQUIRED_ASSETS := ["Bookcase_Full.fbx", "Bag_Coins.fbx", "Coin_Pile.fbx", "Pot1.fbx", "Pot1_Broken.fbx", "Chest_Gold.fbx", "site-generator", "wolf-base", "duck-base"]
const OPTIONAL_ASSETS := ["Doors_RoundArch.fbx", "barred-cell-door", "Cart.fbx", "Skull.fbx", "Cobweb2.fbx", "Candles_2.fbx", "tattered-warning-banner"]

# ---------------------------------------------------------------- state
var level: Node3D
var players_node: Node3D
var hud
var local_player
var rock: StandardMaterial3D
var floor_mat: StandardMaterial3D
var door_mat: StandardMaterial3D
var bark_mat: StandardMaterial3D
var water_mat: StandardMaterial3D
var bone_mat: StandardMaterial3D
var iron_mat: StandardMaterial3D
var copper_mat: StandardMaterial3D
var cloth_mat: StandardMaterial3D
var book_mat: StandardMaterial3D
var ice_mat: StandardMaterial3D
var crystal_teal: StandardMaterial3D
var crystal_violet: StandardMaterial3D
var crystal_amber: StandardMaterial3D
var _drng := RandomNumberGenerator.new()   # decoration only: never touches the gameplay seed
var _dot_tex: Texture2D

var cave := 0               # 0 = lobby, 1..5 = caves
var running := false
var seed_val := 1
var code_digits: Array = []
var code_names := ["RED", "BLUE", "GREEN", "YELLOW"]
var code_colors := [Color(1, 0.25, 0.25), Color(0.35, 0.55, 1), Color(0.3, 1, 0.45), Color(1, 0.9, 0.25)]

var doors := {}             # k -> {node, z, open, base_y, dh, light}
var interactables: Array = []
var creatures := {}
var outline_nodes := {}     # cave -> Array
var planks: Array = []
var wood_count := 0
var gens: Array = []        # index -> {lamp, light}

var loot := {}              # id -> {id, kind, node, vis, hp, coins, pos, cave, broken}
var _loot_n := 0
var _looked := ""           # loot id under the crosshair
var _hit_cd := 0.0
var avoid: Array = []       # Rect2 (x, z) areas already occupied
var hide_spots: Array = []  # Vector3 spots hidden behind rocks / pillars of the cave being built
var _missing := {}          # asset name -> true (could not be found or loaded)

var portal_ready := {}
# ---- treasure quota: the team must collect a share of each cave's loot before its exit opens (makes the run longer)
const QUOTA := 0.65
var _quota_msg_t := 0
var cave_total := {}
var cave_got := {}
var _amb := 0                  # cave whose ambient sounds are running
var _scare_cd := 0.0
var _punch_t := {}             # peer -> last punch time (host)
const PUNCH_DMG := 6.0
const PUNCH_REACH := 1.9
var _waiting := false
var gen_hold := {}          # peer id -> generator index being held (-1 = none)
var gen_progress := 0.0
var gen_done := false
var count_left := 0.0
var _gen_ui_t := 0.0
var _last_mask := -1
var _my_hold_idx := -1
var _role_refresh_t := 0.0
var _death_running := false
var _winning := false
var _env: Environment


# ================================================================ start

func _ready() -> void:
	_setup_materials()
	if not Engine.is_editor_hint():
		add_to_group("world")
		Sfx.play_music()
	if Engine.is_editor_hint():
		_build_level(1234)
		return
	GameNet.ensure_offline_session()
	seed_val = randi()
	_setup_environment()
	Graphics.changed.connect(_on_graphics_changed)
	players_node = Node3D.new()
	players_node.name = "Players"
	add_child(players_node)
	_build_level(seed_val)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.back_pressed.connect(_on_back_pressed)
	hud.code_submitted.connect(_on_code_submitted)
	hud.ui_closed.connect(_on_ui_closed)
	hud.skin_equipped.connect(_on_skin_equipped)
	hud.pet_equipped.connect(_on_pet_equipped)
	hud.lobby_check = func(): return not running
	hud.role_pick_requested.connect(_on_role_pick)
	GameNet.players_changed.connect(_sync_players)
	GameNet.player_left.connect(_on_player_left)
	_sync_players()
	_update_instruction()
	_report_assets()
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		add_child(preload("res://host_code_panel.gd").new())     # room code (top centre) for the host


func _exit_tree() -> void:
	LB.clear_detail_cache()


func _setup_materials() -> void:
	rock = LB.rock_material(Color(0.44, 0.40, 0.36), 0.26, 1)
	floor_mat = LB.rock_material(Color(0.30, 0.28, 0.26), 0.40, 2)
	door_mat = LB.wood_material(Color(0.30, 0.20, 0.13))
	bark_mat = LB.wood_material(Color(0.46, 0.34, 0.22), 0.8)
	var bt := AS.load_texture("Bark_Texture")
	if bt != null:
		bark_mat.albedo_texture = bt
		bark_mat.uv1_triplanar = true
		bark_mat.uv1_world_triplanar = true
		bark_mat.uv1_scale = Vector3(1, 1, 1)
	# --- stage 2 dressing materials (all shared, never one material per prop) ---
	water_mat = LB.material(Color(0.015, 0.03, 0.045))
	water_mat.metallic = 0.45
	water_mat.roughness = 0.05
	water_mat.metallic_specular = 1.0
	water_mat.emission_enabled = true
	water_mat.emission = Color(0.02, 0.06, 0.09)
	water_mat.emission_energy_multiplier = 0.5
	bone_mat = LB.material(Color(0.62, 0.58, 0.47))
	bone_mat.roughness = 0.72
	iron_mat = LB.metal_material(Color(0.16, 0.17, 0.19), 0.42)
	copper_mat = LB.metal_material(Color(0.42, 0.22, 0.10), 0.35)
	cloth_mat = LB.material(Color(0.22, 0.05, 0.05))
	cloth_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	book_mat = LB.material(Color(1, 1, 1))
	book_mat.roughness = 0.85
	book_mat.vertex_color_use_as_albedo = true
	ice_mat = LB.material(Color(0.42, 0.62, 0.78))
	ice_mat.metallic = 0.1
	ice_mat.roughness = 0.08
	ice_mat.emission_enabled = true
	ice_mat.emission = Color(0.10, 0.22, 0.32)
	ice_mat.emission_energy_multiplier = 0.5
	crystal_teal = LB.material(Color(0.25, 0.95, 1.0), 2.6)
	crystal_violet = LB.material(Color(0.68, 0.35, 1.0), 2.6)
	crystal_amber = LB.material(Color(1.0, 0.65, 0.25), 2.2)


func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	Graphics.apply_environment(_env, 0)
	we.environment = _env
	add_child(we)


func _on_graphics_changed() -> void:
	if _env != null:
		Graphics.apply_environment(_env, cave)


# Prints which assets were found (and where) and shows a warning on screen if something needed is missing.
func _report_assets() -> void:
	var bad_required: Array = []
	var bad_optional: Array = []
	print("[ASSETS] ---------- asset check ----------")
	for n in REQUIRED_ASSETS:
		var p: String = AS.find(n)
		if p == "" or AS.load_scene(n) == null:
			bad_required.append(n)
			print("[ASSETS] MISSING/FAILED (required): ", n)
		else:
			print("[ASSETS] OK  ", n, "  ->  ", p)
	for n in OPTIONAL_ASSETS:
		var p: String = AS.find(n)
		if p == "" or AS.load_scene(n) == null:
			bad_optional.append(n)
			print("[ASSETS] missing (optional): ", n)
		else:
			print("[ASSETS] OK  ", n, "  ->  ", p)
	for n in _missing.keys():
		if not bad_required.has(n) and not bad_optional.has(n):
			print("[ASSETS] missing while building: ", n)
	if not bad_required.is_empty():
		push_warning("Missing required assets: " + ", ".join(bad_required))
		hud.show_toast("MISSING ASSETS: " + ", ".join(bad_required) + "\nSee the Output panel. Placeholders are used instead.", Color(1, 0.4, 0.3), 14.0)
	elif not bad_optional.is_empty():
		print("[ASSETS] optional assets missing: ", ", ".join(bad_optional))


# ================================================================ players

func _sorted_ids() -> Array:
	var ids: Array = []
	for c in players_node.get_children():
		ids.append(str(c.name).to_int())
	ids.sort()
	return ids


func _spread(i: int) -> Vector3:
	return Vector3((i % 2) * 2.2 - 1.1, 0.0, -float(i / 2) * 1.8)


func _sync_players() -> void:
	if players_node == null:
		return
	var ids: Array = GameNet.players.keys()
	ids.sort()
	for id in ids:
		var role: String = GameNet.players[id].get("role", "lobby")
		if not players_node.has_node(str(id)):
			var p = PLAYER_SCENE.instantiate()
			p.setup(id, role)
			p.position = LOBBY_SPAWN + _spread(players_node.get_child_count())
			players_node.add_child(p)
			if id == GameNet.my_id():
				_bind_local(p)
		else:
			var pn = players_node.get_node(str(id))
			if pn.role != role:
				pn.set_role(role)
	if hud != null and hud.is_role_open():
		hud.refresh_role_ui(_role_entries())
	_update_instruction()


func _bind_local(p) -> void:
	local_player = p
	p.died.connect(_on_local_died)
	p.hp_changed.connect(_on_hp_changed)
	p.throw_requested.connect(_request_throw)
	p.primary_action.connect(_on_primary_action)
	p.sprint_changed.connect(hud.set_sprint)
	get_tree().create_timer(1.0).timeout.connect(_enable_sync.bind(p))


func _enable_sync(p) -> void:
	if is_instance_valid(p):
		p.sync_enabled = true


func _on_hp_changed(h: float) -> void:
	hud.set_hp(h)


func _on_ui_closed() -> void:
	if local_player != null:
		local_player.ui_open = false


func _on_pet_equipped(id: String) -> void:
	if local_player != null and is_instance_valid(local_player):
		local_player.set_pet(id)


func _on_skin_equipped(i: int) -> void:
	if local_player != null:
		local_player.set_skin(i)


func _on_player_left(id: int) -> void:
	if players_node != null and players_node.has_node(str(id)):
		players_node.get_node(str(id)).queue_free()
	portal_ready.erase(id)
	gen_hold.erase(id)
	if multiplayer.is_server():
		if running:
			# if the blind player leaves, everybody goes back to the lobby
			var left_role := ""
			if GameNet.players.has(id):
				left_role = GameNet.players[id].get("role", "")
			if players_node.get_child_count() <= 1 or left_role == "carrier":
				_host_return_lobby()
		else:
			_check_portal_start()


# ================================================================ main loop

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or local_player == null or not is_instance_valid(local_player):
		return
	_hit_cd = maxf(0.0, _hit_cd - delta)
	_local_interact_tick()
	if hud.is_role_open():
		_role_refresh_t += delta
		if _role_refresh_t > 0.5:
			_role_refresh_t = 0.0
			hud.refresh_role_ui(_role_entries())
	if running and local_player.global_position.y < FALL_Y and not _death_running and not local_player.frozen:
		_on_local_died()
	if multiplayer.is_server():
		_host_tick(delta)


# ---------------------------------------------------------------- interaction (E = stations / generators, Left Click = loot)

func _add_interact(id: String, pos: Vector3, radius: float, prompt: String, cave_id: int, hold: bool = false, node: Node = null) -> void:
	interactables.append({"id": id, "pos": pos, "r": radius, "prompt": prompt, "cave": cave_id, "hold": hold, "node": node})


func _local_interact_tick() -> void:
	_looked = ""
	if hud.is_ui_open() or local_player.frozen:
		hud.set_prompt("")
		_set_hold(-1)
		return
	var ppos: Vector3 = local_player.global_position
	var best = null
	var best_d := 9999.0
	for it in interactables:
		if it["cave"] != cave:
			continue
		var d: float = Vector2(ppos.x - it["pos"].x, ppos.z - it["pos"].z).length()
		if d <= it["r"] and absf(ppos.y - it["pos"].y) < 3.5 and d < best_d:
			best = it
			best_d = d
	# loot under the crosshair (the blind player cannot see loot, so he does not interact with it)
	if not local_player.is_carrier:
		var hit: Dictionary = local_player.look_ray(LOOT_REACH, 1 | LOOT_LAYER)
		if not hit.is_empty():
			var c = hit.get("collider")
			if c != null and (c as Node).has_meta("loot_id"):
				_looked = str((c as Node).get_meta("loot_id"))
	if best != null:
		hud.set_prompt(best["prompt"])
		if best["hold"]:
			if Input.is_action_pressed("interact"):
				_set_hold(int(str(best["id"]).substr(4)))
			else:
				_set_hold(-1)
		else:
			_set_hold(-1)
			if Input.is_action_just_pressed("interact"):
				_activate(best)
	elif _looked != "" and loot.has(_looked):
		hud.set_prompt(_loot_prompt(loot[_looked]))
		_set_hold(-1)
	else:
		hud.set_prompt("")
		_set_hold(-1)


func _activate(it: Dictionary) -> void:
	var id: String = it["id"]
	if id == "skin":
		local_player.ui_open = true
		hud.open_skin_ui()
	elif id == "roles":
		local_player.ui_open = true
		hud.open_role_ui(_role_entries(), GameNet.my_id())
	elif id == "keypad":
		local_player.ui_open = true
		var hint := "Enter the digits for:  "
		for i in range(code_names.size()):
			hint += "[color=#%s][b]%s[/b][/color]  " % [(code_colors[i] as Color).to_html(false), code_names[i]]
		hud.open_keypad(hint, code_names.size())
	elif id.begins_with("stone_") or id.begins_with("wood_"):
		if multiplayer.is_server():
			_host_pickup(id, 1)
		else:
			rpc_request_pickup.rpc_id(1, id)


# generator being held by me (-1 = none)
func _set_hold(idx: int) -> void:
	if idx == _my_hold_idx:
		return
	_my_hold_idx = idx
	if multiplayer.is_server():
		gen_hold[1] = idx
	else:
		rpc_hold.rpc_id(1, idx)


@rpc("any_peer", "reliable")
func rpc_hold(idx: int) -> void:
	if not multiplayer.is_server():
		return
	gen_hold[multiplayer.get_remote_sender_id()] = idx


# ---------------------------------------------------------------- Role Changer

func _role_entries() -> Array:
	var out: Array = []
	var ids: Array = GameNet.players.keys()
	ids.sort()
	for id in ids:
		var skin := 0
		if players_node != null and players_node.has_node(str(id)):
			var pn = players_node.get_node(str(id))
			skin = pn.skin_idx
		out.append({
			"id": id,
			"name": str(GameNet.players[id].get("name", "Player")),
			"skin": skin,
			"blind": GameNet.players[id].get("pref", "sighted") == "blind",
		})
	return out


func _on_role_pick(id: int) -> void:
	GameNet.request_blind(id)


# ---------------------------------------------------------------- pick up (stones / wood)

@rpc("any_peer", "reliable")
func rpc_request_pickup(id: String) -> void:
	if multiplayer.is_server():
		_host_pickup(id, multiplayer.get_remote_sender_id())


func _host_pickup(id: String, who: int) -> void:
	for it in interactables:
		if it["id"] == id:
			rpc_do_pickup.rpc(id, who)
			return


@rpc("authority", "call_local", "reliable")
func rpc_do_pickup(id: String, who: int) -> void:
	for i in range(interactables.size()):
		if interactables[i]["id"] == id:
			var n = interactables[i]["node"]
			if n != null and is_instance_valid(n):
				n.queue_free()
			interactables.remove_at(i)
			break
	if id.begins_with("wood_"):
		wood_count += 1
		_update_planks()
	if who == GameNet.my_id() and local_player != null and id.begins_with("stone_"):
		local_player.stones += 1
	_update_items_label()


func _quota_need(c: int) -> int:
	return int(float(cave_total.get(c, 0)) * QUOTA)


func _quota_met(c: int) -> bool:
	return int(cave_got.get(c, 0)) >= _quota_need(c)


@rpc("authority", "call_local", "reliable")
func rpc_toast(text: String) -> void:
	if hud != null:
		hud.show_toast(text, Color(1, 0.7, 0.3), 3.0)


func _update_items_label() -> void:
	if hud == null or local_player == null:
		return
	var s := ""
	if running and cave != 3 and cave >= 1 and _quota_need(cave) > 0:
		s += "Treasure: %d / %d   " % [mini(int(cave_got.get(cave, 0)), _quota_need(cave)), _quota_need(cave)]
	if cave >= 4:
		s += "Stones: %d" % local_player.stones
	if cave >= 5:
		s += "   Wood: %d/4" % wood_count
	hud.set_items(s)


func _update_planks() -> void:
	for i in range(planks.size()):
		var on: bool = i < wood_count
		var b = planks[i]
		b.visible = on
		b.collision_layer = 1 if on else 0


# ================================================================ loot (bags, coin piles, vases, chests)

func _loot_prompt(e: Dictionary) -> String:
	match e["kind"]:
		"bag":
			return "Left Click - Take Money Bag (+%d)" % int(e["coins"])
		"pile":
			return "Left Click - Take Coins (+%d)" % int(e["coins"])
		"pot":
			var left: int = int(e["hp"]) - (0 if e["broken"] else POT_BROKEN_AT)
			return "Left Click - Smash the vase (%d hits)" % maxi(left, 1)
		"chest":
			return "Left Click - Break the chest (%d hits)" % int(e["hp"])
	return ""


func _on_primary_action() -> void:
	if _hit_cd > 0.0 or hud.is_ui_open() or local_player.frozen:
		return
	if _try_sword():
		return
	if _looked != "" and loot.has(_looked) and not local_player.is_carrier:
		_hit_cd = HIT_COOLDOWN
		if multiplayer.is_server():
			_host_loot_hit(_looked, GameNet.my_id())
		else:
			rpc_loot_request.rpc_id(1, _looked)
		return
	_try_punch()


# ---- sword (Cave 5): hits the duck only while it holds a player (counted on the host)
func _try_sword() -> bool:
	if not local_player.has_sword or not creatures.has("duck"):
		return false
	var d = creatures["duck"]
	if Vector2(d.global_position.x - local_player.global_position.x, d.global_position.z - local_player.global_position.z).length() > 3.4:
		return false
	_hit_cd = 0.35
	local_player.swing()
	if multiplayer.is_server():
		d.sword_hit()
	else:
		rpc_sword_request.rpc_id(1)
	return true


@rpc("any_peer", "reliable")
func rpc_sword_request() -> void:
	if not multiplayer.is_server() or not creatures.has("duck"):
		return
	var pn = players_node.get_node_or_null(str(multiplayer.get_remote_sender_id()))
	var d = creatures["duck"]
	if pn != null and pn.global_position.distance_to(d.global_position) < 5.0:
		d.sword_hit()


# ---- PvP punch: left click on a player in front of you
func _try_punch() -> void:
	if not running:
		return
	var fwd: Vector3 = -local_player.camera.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var best := -1
	var best_d := PUNCH_REACH
	for c in players_node.get_children():
		var id := str(c.name).to_int()
		if id == GameNet.my_id():
			continue
		var off: Vector3 = c.global_position - local_player.global_position
		var dist := Vector2(off.x, off.z).length()
		off.y = 0.0
		if dist < best_d and (dist < 0.8 or fwd.dot(off.normalized()) > 0.5):
			best = id
			best_d = dist
	if best < 0:
		return
	_hit_cd = 0.6
	if multiplayer.is_server():
		_host_punch(GameNet.my_id(), best)
	else:
		rpc_punch_request.rpc_id(1, best)


@rpc("any_peer", "reliable")
func rpc_punch_request(target: int) -> void:
	if multiplayer.is_server():
		_host_punch(multiplayer.get_remote_sender_id(), target)


func _host_punch(who: int, target: int) -> void:
	var a = players_node.get_node_or_null(str(who))
	var t = players_node.get_node_or_null(str(target))
	if a == null or t == null or a.global_position.distance_to(t.global_position) > PUNCH_REACH + 1.2:
		return
	var now := Time.get_ticks_msec()
	if now - int(_punch_t.get(who, -10000)) < 450:
		return
	_punch_t[who] = now
	if target == 1 or not GameNet.has_other_peers():
		t.rpc_damage(PUNCH_DMG)
	else:
		t.rpc_damage.rpc_id(target, PUNCH_DMG)
	a.rpc_attack_anim.rpc()
	rpc_sfx.rpc("punch")


# ---- sounds everybody hears
func sfx_all(key: String) -> void:
	if not multiplayer.is_server():
		return
	if key == "scare":
		var now := Time.get_ticks_msec() / 1000.0
		if now < _scare_cd:
			return
		_scare_cd = now + 2.5
	rpc_sfx.rpc(key)


@rpc("authority", "call_local", "reliable")
func rpc_sfx(key: String) -> void:
	Sfx.play(key)


func _cave_audio() -> void:
	if Engine.is_editor_hint():
		return
	if running and cave == 4 and _amb != 4:
		Sfx.loop_gap("howl", 5.0, func(): return running and cave == 4)
	if running and cave == 5 and _amb != 5:
		Sfx.play("witch")
		Sfx.loop_gap("quack", 5.0, func(): return running and cave == 5)
	_amb = cave if running else 0
	if local_player != null and is_instance_valid(local_player):
		local_player.set_sword(running and cave == 5 and not local_player.is_carrier)


@rpc("any_peer", "reliable")
func rpc_loot_request(id: String) -> void:
	if multiplayer.is_server():
		_host_loot_hit(id, multiplayer.get_remote_sender_id())


# the host decides what a hit does
func _host_loot_hit(id: String, who: int) -> void:
	if not loot.has(id):
		return
	var e: Dictionary = loot[id]
	var pn = players_node.get_node_or_null(str(who))
	if pn == null or pn.global_position.distance_to(e["pos"]) > LOOT_REACH + 2.5:
		return
	if e["kind"] == "bag" or e["kind"] == "pile":
		rpc_loot_collect.rpc(id, who)
	else:
		rpc_loot_hp.rpc(id, int(e["hp"]) - 1)


# bag / pile collected: removed everywhere, the collector gets the coins
@rpc("authority", "call_local", "reliable")
func rpc_loot_collect(id: String, who: int) -> void:
	if not loot.has(id):
		return
	var e: Dictionary = loot[id]
	_free_loot(id)
	cave_got[int(e["cave"])] = int(cave_got.get(int(e["cave"]), 0)) + int(e["coins"])
	_update_items_label()
	if who == GameNet.my_id():
		GameNet.add_coins(int(e["coins"]))
		if hud != null:
			hud.show_toast("+%d coins" % int(e["coins"]), Color(1, 0.85, 0.2), 1.6)


# vase / chest hit: hp goes down, model changes, drops appear when it is destroyed
@rpc("authority", "call_local", "reliable")
func rpc_loot_hp(id: String, hp: int) -> void:
	if not loot.has(id):
		return
	var e: Dictionary = loot[id]
	e["hp"] = hp
	_punch(e)
	if hp <= 0:
		var pos: Vector3 = e["pos"]
		var kind: String = e["kind"]
		var cave_id: int = e["cave"]
		if kind == "pot":
			Sfx.play("vase", pos)
		_free_loot(id)
		var each := POT_DROP_COINS if kind == "pot" else CHEST_DROP_COINS
		for k in range(3):
			var ang := TAU / 3.0 * float(k) + float(id.hash() % 100) * 0.1
			var p := pos + Vector3(cos(ang), 0.0, sin(ang)) * 0.55
			_make_loot("pile", p, ang, cave_id, {"id": id + "_d%d" % k, "coins": each, "drop": true})
	elif e["kind"] == "pot" and hp <= POT_BROKEN_AT and not e["broken"]:
		_swap_pot_model(e)


func _free_loot(id: String) -> void:
	if not loot.has(id):
		return
	var n = loot[id]["node"]
	if n != null and is_instance_valid(n):
		n.queue_free()
	loot.erase(id)


func _punch(e: Dictionary) -> void:
	var v = e["vis"]
	if v == null or not is_instance_valid(v):
		return
	var tw := create_tween()
	tw.tween_property(v, "scale", Vector3(1.12, 0.9, 1.12), 0.05)
	tw.tween_property(v, "scale", Vector3.ONE, 0.14)


func _swap_pot_model(e: Dictionary) -> void:
	var vis: Node3D = e["vis"]
	for c in vis.get_children():
		c.queue_free()
	var m := _fit_model("Pot1_Broken.fbx", 0.61, false)
	if m != null:
		vis.add_child(m)
	else:
		vis.add_child(_fallback_mesh("pot", 0.6))
	e["broken"] = true


func _fit_model(part: String, h: float, longest: bool = false) -> Node3D:
	var m := AS.instance_fitted(part, h, longest)
	if m == null:
		_missing[part] = true
	return m


func _fallback_mesh(kind: String, mul: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.2 * mul
	cm.bottom_radius = 0.25 * mul
	cm.height = 0.5 * mul
	cm.material = LB.material(Color(1, 0.8, 0.1) if kind == "bag" or kind == "pile" else Color(0.55, 0.35, 0.2), 0.5)
	mi.mesh = cm
	mi.position.y = cm.height / 2.0
	return mi


# opts: id (fixed id), mul (size multiplier), coins (override value)
func _make_loot(kind: String, pos: Vector3, yaw: float, cave_id: int, opts: Dictionary = {}) -> String:
	var def: Dictionary = LOOT_DEF[kind]
	var id: String = opts.get("id", "")
	if id == "":
		_loot_n += 1
		id = "loot_%d" % _loot_n
	var mul: float = opts.get("mul", 1.0)
	var body := StaticBody3D.new()
	body.name = id
	body.collision_layer = LOOT_LAYER | (1 if def["solid"] else 0)
	body.collision_mask = 0
	body.position = pos
	body.rotation.y = yaw
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var sz: Vector3 = def["box"]
	sz *= mul
	bs.size = sz
	cs.shape = bs
	cs.position.y = sz.y / 2.0
	body.add_child(cs)
	var vis := Node3D.new()
	body.add_child(vis)
	var model := _fit_model(def["file"], float(def["fit"]) * mul, def["longest"])
	if model != null:
		vis.add_child(model)
	else:
		vis.add_child(_fallback_mesh(kind, mul))
	level.add_child(body)
	body.set_meta("loot_id", id)
	if not opts.get("drop", false):
		var pot_coins := int(opts.get("coins", def["coins"]))
		if kind == "pot":
			pot_coins = POT_DROP_COINS * 3
		elif kind == "chest":
			pot_coins = CHEST_DROP_COINS * 3
		cave_total[cave_id] = int(cave_total.get(cave_id, 0)) + pot_coins
	loot[id] = {
		"id": id, "kind": kind, "node": body, "vis": vis, "hp": int(def["hp"]),
		"coins": int(opts.get("coins", def["coins"])), "pos": pos, "cave": cave_id, "broken": false,
	}
	return id


# ---------------------------------------------------------------- stones

func _request_throw(origin: Vector3, dir: Vector3) -> void:
	rpc_spawn_stone.rpc(origin, dir * 13.0 + Vector3(0, 2.5, 0))
	_update_items_label()


@rpc("any_peer", "call_local", "reliable")
func rpc_spawn_stone(origin: Vector3, vel: Vector3) -> void:
	var rb := RigidBody3D.new()
	rb.position = origin
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.13
	cs.shape = sph
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.material = LB.material(Color(0.45, 0.45, 0.47))
	mi.mesh = sm
	rb.add_child(mi)
	rb.contact_monitor = true
	rb.max_contacts_reported = 2
	level.add_child(rb)
	rb.linear_velocity = vel
	var fired := [false]
	rb.body_entered.connect(_on_stone_hit.bind(rb, fired))
	get_tree().create_timer(8.0).timeout.connect(_free_if_valid.bind(rb))


func _on_stone_hit(_body: Node, rb: RigidBody3D, fired: Array) -> void:
	if fired[0] or not is_instance_valid(rb):
		return
	fired[0] = true
	Sfx.play("rock", rb.global_position)
	if multiplayer.is_server():
		for k in creatures.keys():
			creatures[k].hear_noise(rb.global_position, 28.0)


func _free_if_valid(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()


# ================================================================ lobby portal and run start

func _on_portal(body: Node3D) -> void:
	if running or _waiting or local_player == null or body != local_player:
		return
	_waiting = true
	local_player.frozen = true
	local_player.ui_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_waiting(true, "Waiting for other players... (1/%d)" % players_node.get_child_count(), players_node.get_child_count() < 2)
	if multiplayer.is_server():
		portal_ready[1] = true
		# Deferred: the portal's body_entered arrives inside a physics callback and
		# _build_level replaces the whole level, which is illegal mid-step.
		call_deferred("_check_portal_start")
	else:
		rpc_portal_state.rpc_id(1, true)


func _on_back_pressed() -> void:
	if not _waiting:
		return
	_waiting = false
	hud.show_waiting(false)
	local_player.global_position += Vector3(0, 0, 4.5)
	local_player.frozen = false
	local_player.ui_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if multiplayer.is_server():
		portal_ready[1] = false
		_check_portal_start()
	else:
		rpc_portal_state.rpc_id(1, false)


@rpc("any_peer", "reliable")
func rpc_portal_state(v: bool) -> void:
	if not multiplayer.is_server():
		return
	portal_ready[multiplayer.get_remote_sender_id()] = v
	_check_portal_start()


func _check_portal_start() -> void:
	if running:
		return
	var total := players_node.get_child_count()
	var ready := 0
	for id in portal_ready.keys():
		if portal_ready[id] and players_node.has_node(str(id)):
			ready += 1
	rpc_wait_ui.rpc(ready, total)
	if total >= 2 and ready >= total:          # never start alone
		_host_start_run()


@rpc("authority", "call_local", "reliable")
func rpc_wait_ui(ready: int, total: int) -> void:
	if _waiting:
		hud.show_waiting(true, "Waiting for other players... (%d/%d)" % [ready, total], total < 2)


# The roles chosen in the Role Changer are applied HERE (only when the run starts). Exactly one blind player.
func _host_start_run() -> void:
	var ids := _sorted_ids()
	var carrier: int = GameNet.blind_id()
	if carrier < 0 or not ids.has(carrier):
		carrier = ids[ids.size() - 1]
	var roles := {}
	for id in ids:
		roles[id] = "carrier" if id == carrier else "guide"
	GameNet.in_game = true
	portal_ready.clear()
	rpc_begin_run.rpc(randi(), roles)


@rpc("authority", "call_local", "reliable")
func rpc_begin_run(new_seed: int, roles: Dictionary) -> void:
	GameNet.in_game = true
	for id in roles.keys():
		if GameNet.players.has(id):
			GameNet.players[id]["role"] = roles[id]
		if players_node.has_node(str(id)):
			players_node.get_node(str(id)).set_role(roles[id])
	_build_level(new_seed)
	running = true
	cave = 1
	wood_count = 0
	gen_progress = 0.0
	gen_done = false
	gen_hold.clear()
	_my_hold_idx = -1
	_last_mask = -1
	_waiting = false
	_winning = false
	hud.show_waiting(false)
	hud.show_message(false)
	hud.show_progress(false)
	hud.show_countdown(false)
	var ids := _sorted_ids()
	if local_player != null:
		var idx := ids.find(GameNet.my_id())
		local_player.stones = 0
		local_player.respawn(CAVE_START[1] + _spread(maxi(idx, 0)), 0.0)
		local_player.frozen = false
		local_player.ui_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_cave_state()


@rpc("authority", "call_local", "reliable")
func rpc_set_cave(c: int) -> void:
	cave = c
	_apply_cave_state()


func _apply_cave_state() -> void:
	Graphics.set_cave(cave)
	if _env != null:
		Graphics.apply_environment(_env, cave)
	_cave_audio()
	_update_items_label()
	for k in creatures.keys():
		var kk: int = 4 if k == "wolf" else 5
		creatures[k].active = running and cave == kk
	for k in outline_nodes.keys():
		for n in outline_nodes[k]:
			if is_instance_valid(n):
				n.visible = (k == cave)
	_update_instruction()
	_update_items_label()


func _update_instruction() -> void:
	if hud == null:
		return
	var texts := {
		0: "LOBBY\nWalk into the yellow portal to begin.\nE at the Skin Station (left) = skins.\nE at the Role Changer (right) = choose who is Blind.",
		1: "CAVE 1 - Tutorial\nWASD move, Space jump, Ctrl crouch (quiet).\nLeft Click on loot (bags, coins, vases) to collect / smash.\nCollect the treasure quota (shown bottom-right), then guide everyone through the far door.",
		2: "CAVE 2 - The Code\nFind the 4 coloured plaques (each colour is a digit).\nType the digits on the keypad (E) by the exit door, in the order shown.\nThe door also needs the treasure quota.",
		3: "CAVE 3 - Generators\n4 generators, one at the end of each side corridor.\nEach of the 4 players holds E at a different generator for 4 seconds, all at the same time.\nThen reach the exit door within 30 seconds!",
		4: "CAVE 4 - The Wolf\nThe wolf hears everything. Hold Ctrl to sneak.\nPick up stones (E) and throw them (G) to lure it away.\nThe exit needs the treasure quota.",
		5: "CAVE 5 - The Echo\nCollect 4 wood (E) to build the bridge.\nAvoid the Duck Monster. The portal needs the treasure quota. Touch it to escape.",
	}
	var t: String = texts.get(cave, "")
	if running and local_player != null:
		if local_player.is_carrier:
			t += "\n\nYOU ARE BLIND. F = flashlight. Q = Echo Ping (shows walls for 2 s, 8 s cooldown; monsters hear it). Listen: heartbeat = monster near, jingle = treasure near."
		else:
			t += "\n\nYou are SIGHTED: you only see ~1 m around you. Guide the blind player, his flashlight lights the way."
	hud.set_instruction(t)


# ================================================================ host logic

func _all_players() -> Array:
	return players_node.get_children()


func _all_past(z_line: float) -> bool:
	var ps := _all_players()
	if ps.is_empty():
		return false
	for p in ps:
		if p.global_position.z >= z_line:
			return false
	return true


func _host_tick(delta: float) -> void:
	if not running:
		return
	match cave:
		1:
			if not doors[1]["open"] and _all_past(-64.0) and _quota_met(1):
				rpc_door.rpc(1, true)
		4:
			if not doors[4]["open"] and _all_past(-252.0) and _quota_met(4):
				rpc_door.rpc(4, true)
		3:
			_gen_tick(delta)
	# when everybody is through the door: close it and go to the next cave
	if cave >= 1 and cave <= 4 and doors.has(cave) and doors[cave]["open"]:
		if _all_past(DOOR_Z[cave] - 2.0):
			var k := cave
			rpc_door.rpc(k, false)
			if k == 3:
				rpc_gen_ui.rpc(false, 0.0, 0, 0)
				rpc_count_ui.rpc(false, 0.0, 0)
			rpc_set_cave.rpc(k + 1)


func _popcount(m: int) -> int:
	var n := 0
	for i in range(GEN_COUNT):
		if (m >> i) & 1 == 1:
			n += 1
	return n


# Every generator must be held by a DIFFERENT player at the same time, for GEN_TIME seconds in a row.
func _gen_tick(delta: float) -> void:
	var total := players_node.get_child_count()
	var needed := GEN_COUNT
	if GEN_ALLOW_FEWER_PLAYERS:
		needed = mini(GEN_COUNT, maxi(total, 1))
	var mask := 0
	for id in gen_hold.keys():
		var idx: int = gen_hold[id]
		if idx >= 0 and idx < GEN_COUNT and players_node.has_node(str(id)):
			mask |= (1 << idx)
	var held := _popcount(mask)
	# EVERY active player must hold E at the same time, each on a different generator
	var players_total := maxi(GameNet.players.size(), total)
	var holders := 0
	for id in gen_hold.keys():
		if int(gen_hold[id]) >= 0 and players_node.has_node(str(id)):
			holders += 1
	var all_hold := holders >= players_total and held >= needed
	_gen_ui_t += delta
	if not gen_done:
		if all_hold and total > 0:
			gen_progress += delta
		else:
			gen_progress = 0.0                                       # one player let go: back to 0
		if mask != _last_mask:
			_last_mask = mask
			rpc_gen_lamps.rpc(mask, false)
		if gen_progress >= GEN_TIME:
			gen_done = true
			count_left = COUNT_TIME
			rpc_door.rpc(3, true)
			rpc_gen_ui.rpc(false, 1.0, mask, needed)
			rpc_gen_lamps.rpc(mask, true)
		elif _gen_ui_t > 0.1:
			_gen_ui_t = 0.0
			rpc_gen_ui.rpc(held > 0 or gen_progress > 0.0, gen_progress / GEN_TIME, mask, needed)
	else:
		count_left -= delta
		if _gen_ui_t > 0.1:
			_gen_ui_t = 0.0
			rpc_count_ui.rpc(true, count_left / COUNT_TIME, int(ceil(count_left)))
		if count_left <= 0.0:
			count_left = 0.0
			rpc_count_ui.rpc(false, 0.0, 0)
			_host_team_death("Time's up!", 3)


@rpc("authority", "call_local", "unreliable")
func rpc_gen_ui(show_it: bool, value: float, mask: int, needed: int) -> void:
	hud.show_progress(show_it, value, "Generators held: %d / %d  (hold E, all together)" % [_popcount(mask), needed])


@rpc("authority", "call_local", "reliable")
func rpc_count_ui(show_it: bool, value: float, secs: int) -> void:
	hud.show_countdown(show_it, value, "Reach the exit door!  %d" % secs)


# each generator has a status light: red = nobody, yellow = being held, green = powered
@rpc("authority", "call_local", "reliable")
func rpc_gen_lamps(mask: int, done: bool) -> void:
	for i in range(gens.size()):
		var g: Dictionary = gens[i]
		var c := Color(1, 0.15, 0.1)
		if done:
			c = Color(0.2, 1, 0.3)
		elif (mask >> i) & 1 == 1:
			c = Color(1, 0.8, 0.1)
		var lamp = g["lamp"]
		if lamp != null and is_instance_valid(lamp):
			var m := (lamp as MeshInstance3D).material_override as StandardMaterial3D
			if m != null:
				m.albedo_color = c
				m.emission = c
		var l = g["light"]
		if l != null and is_instance_valid(l):
			(l as OmniLight3D).light_color = c


# ---------------------------------------------------------------- doors

@rpc("authority", "call_local", "reliable")
func rpc_door(k: int, open: bool) -> void:
	if not doors.has(k):
		return
	var d: Dictionary = doors[k]
	d["open"] = open
	var node: Node3D = d["node"]
	var target: float = d["base_y"] + (d["dh"] + 0.4 if open else 0.0)
	var tw := create_tween()
	tw.tween_property(node, "position:y", target, 1.3)
	var l: OmniLight3D = d["light"]
	if l != null:
		l.light_color = Color(0.3, 1, 0.4) if open else Color(1, 0.2, 0.15)


# ---------------------------------------------------------------- keypad

func _on_code_submitted(code: String) -> void:
	if multiplayer.is_server():
		_host_check_code(code, 1)
	else:
		rpc_submit_code.rpc_id(1, code)


@rpc("any_peer", "reliable")
func rpc_submit_code(code: String) -> void:
	if multiplayer.is_server():
		_host_check_code(code, multiplayer.get_remote_sender_id())


func _host_check_code(code: String, sender: int) -> void:
	var correct := ""
	for d in code_digits:
		correct += str(d)
	var ok := (code == correct)
	if sender == 1:
		rpc_code_result(ok)
	else:
		rpc_code_result.rpc_id(sender, ok)
	if ok and cave == 2 and not doors[2]["open"]:
		if _quota_met(2):
			rpc_door.rpc(2, true)
		else:
			rpc_toast.rpc("Code accepted, but the door needs treasure: %d / %d coins" % [int(cave_got.get(2, 0)), _quota_need(2)])


@rpc("authority", "call_local", "reliable")
func rpc_code_result(ok: bool) -> void:
	hud.keypad_feedback(ok)


# ---------------------------------------------------------------- team death

func _on_local_died() -> void:
	if _death_running or not running:
		return
	if multiplayer.is_server():
		_host_team_death("You died", cave)
	else:
		rpc_report_death.rpc_id(1, cave)


@rpc("any_peer", "reliable")
func rpc_report_death(c: int) -> void:
	if multiplayer.is_server():
		_host_team_death("You died", c)


func _host_team_death(title: String, c: int) -> void:
	if _death_running:
		return
	rpc_death.rpc(title, c)


@rpc("authority", "call_local", "reliable")
func rpc_death(title: String, c: int) -> void:
	if _death_running:
		return
	_death_running = true
	hud.show_progress(false)
	hud.show_countdown(false)
	hud.death_label.text = title
	if local_player != null:
		local_player.frozen = true
		local_player.ui_open = false
	if players_node != null:
		for p in players_node.get_children():
			if p.has_method("play_death"):
				p.play_death()
	hud.close_panels()
	for s in [3, 2, 1]:
		hud.show_death(true, "Respawning in %d" % s)
		await get_tree().create_timer(1.0).timeout
	if multiplayer.is_server():
		_host_reset_cave(c)
	var ids := _sorted_ids()
	if local_player != null and is_instance_valid(local_player):
		var idx := ids.find(GameNet.my_id())
		local_player.respawn(CAVE_START[clampi(c, 1, 5)] + _spread(maxi(idx, 0)), 0.0)
		local_player.frozen = false
	hud.show_death(false)
	hud.set_hp(100.0)
	_death_running = false


func _host_reset_cave(c: int) -> void:
	for k in creatures.keys():
		creatures[k].reset()
	if c == 3:
		gen_progress = 0.0
		gen_done = false
		count_left = 0.0
		gen_hold.clear()
		_my_hold_idx = -1
		_last_mask = -1
		rpc_door.rpc(3, false)
		rpc_gen_lamps.rpc(0, false)
		rpc_gen_ui.rpc(false, 0.0, 0, 0)
		rpc_count_ui.rpc(false, 0.0, 0)


# ---------------------------------------------------------------- win

func _on_final_portal(body: Node3D) -> void:
	if not running or _winning or not multiplayer.is_server():
		return
	if body is CharacterBody3D and body.is_in_group("players"):
		if not _quota_met(5):
			if Time.get_ticks_msec() - _quota_msg_t > 3000:
				_quota_msg_t = Time.get_ticks_msec()
				rpc_toast.rpc("The portal needs treasure: %d / %d coins" % [int(cave_got.get(5, 0)), _quota_need(5)])
			return
		_winning = true
		rpc_win.rpc()
		await get_tree().create_timer(6.0).timeout
		_host_return_lobby()


@rpc("authority", "call_local", "reliable")
func rpc_win() -> void:
	_winning = true
	hud.show_message(true, "Congratulations!", "You escaped the cave. Returning to the lobby...")
	if local_player != null:
		local_player.frozen = true


func _host_return_lobby() -> void:
	var roles := {}
	for id in _sorted_ids():
		roles[id] = "lobby"
	GameNet.in_game = false
	rpc_return_lobby.rpc(randi(), roles)


@rpc("authority", "call_local", "reliable")
func rpc_return_lobby(new_seed: int, roles: Dictionary) -> void:
	GameNet.in_game = false
	for id in roles.keys():
		if GameNet.players.has(id):
			GameNet.players[id]["role"] = "lobby"
		if players_node.has_node(str(id)):
			players_node.get_node(str(id)).set_role("lobby")
	running = false
	_winning = false
	_waiting = false
	_death_running = false
	portal_ready.clear()
	_build_level(new_seed)
	cave = 0
	_cave_audio()
	hud.show_message(false)
	hud.show_death(false)
	hud.show_waiting(false)
	hud.show_progress(false)
	hud.show_countdown(false)
	hud.set_hp(100.0)
	var ids := _sorted_ids()
	if local_player != null:
		var idx := ids.find(GameNet.my_id())
		local_player.respawn(LOBBY_SPAWN + _spread(maxi(idx, 0)), 0.0)
		local_player.frozen = false
		local_player.ui_open = false
		local_player.stones = 0
	_apply_cave_state()


# ================================================================ building the world

func _build_level(s: int) -> void:
	if level != null and is_instance_valid(level):
		remove_child(level)
		level.queue_free()
	level = Node3D.new()
	level.name = "Level"
	add_child(level)
	doors.clear()
	cave_total.clear()
	cave_got.clear()
	interactables.clear()
	creatures.clear()
	outline_nodes.clear()
	planks.clear()
	gens.clear()
	loot.clear()
	avoid.clear()
	hide_spots.clear()
	_loot_n = 0
	_looked = ""
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	_drng.seed = s * 7919 + 17       # separate stream: decor never shifts loot / rocks / hiding spots
	code_digits = []
	for i in range(4):
		code_digits.append(rng.randi_range(0, 9))
	_build_lobby(rng)
	_build_cave1(rng)
	_build_cave2(rng)
	_build_cave3(rng)
	_build_cave4(rng)
	_build_cave5(rng)


# ---------------------------------------------------------------- building tools

func _floor(x0: float, x1: float, z0: float, z1: float) -> void:
	LB.box(level, x0, x1, -1.0, 0.0, z0, z1, floor_mat)


func _ceil(x0: float, x1: float, z0: float, z1: float, h: float) -> void:
	LB.box(level, x0, x1, h, h + 1.0, z0, z1, rock)


func _segments(a: float, b: float, gaps: Array) -> Array:
	var segs: Array = []
	var cur := a
	for g in gaps:
		if g.x > cur:
			segs.append(Vector2(cur, g.x))
		cur = maxf(cur, g.y)
	if cur < b:
		segs.append(Vector2(cur, b))
	return segs


# long wall along z at x_in (thickness goes outward by sgn). Gaps: Vector3(from, to, gap height), sorted by "from"
func _wall_side(x_in: float, sgn: float, z0: float, z1: float, h: float, gaps: Array = []) -> void:
	var xb := x_in + sgn * 1.0
	for sg in _segments(z0, z1, gaps):
		LB.box(level, x_in, xb, 0.0, h, sg.x, sg.y, rock)
	for g in gaps:
		if g.z < h:
			LB.box(level, x_in, xb, g.z, h, g.x, g.y, rock)


func _wall_front(z_in: float, sgn: float, x0: float, x1: float, h: float) -> void:
	LB.box(level, x0, x1, 0.0, h, z_in, z_in + sgn * 1.0, rock)


# wall between two caves (a door in the middle)
func _end_wall(z: float, xmin: float, xmax: float, h: float, dx: float, dw: float, dh: float) -> void:
	if dw <= 0.0:
		LB.box(level, xmin, xmax, 0.0, h, z - 0.5, z + 0.5, rock)
		return
	LB.box(level, xmin, dx - dw / 2.0, 0.0, h, z - 0.5, z + 0.5, rock)
	LB.box(level, dx + dw / 2.0, xmax, 0.0, h, z - 0.5, z + 0.5, rock)
	LB.box(level, dx - dw / 2.0, dx + dw / 2.0, dh, h, z - 0.5, z + 0.5, rock)


# sliding door: dark slab (collision) + the round-arch door model in front of it
func _make_door(k: int, dx: float, z: float, dw: float, dh: float) -> void:
	var body := LB.box(level, dx - dw / 2.0, dx + dw / 2.0, 0.0, dh, z - 0.3, z + 0.3, door_mat)
	var arch := AS.instance_fitted("Doors_RoundArch.fbx", dh - 0.15)
	if arch != null:
		body.add_child(arch)
		arch.position = Vector3(0, -dh / 2.0, 0.32)
	else:
		_missing["Doors_RoundArch.fbx"] = true
	var lamp := LB.light(level, Vector3(dx, dh + 0.5, z + 1.2), Color(1, 0.2, 0.15), 1.2, 5.0)
	doors[k] = {"node": body, "z": z, "open": false, "base_y": body.position.y, "dh": dh, "light": lamp}


func _hall(x0: float, x1: float, z0: float, z1: float, h: float) -> void:
	_floor(x0 - 1.0, x1 + 1.0, z0 - 0.5, z1 + 0.5)
	_ceil(x0 - 1.0, x1 + 1.0, z0 - 0.5, z1 + 0.5, h)
	_wall_side(x0, -1.0, z0 - 0.5, z1 + 0.5, h)
	_wall_side(x1, 1.0, z0 - 0.5, z1 + 0.5, h)


func _decor(part: String, height: float, pos: Vector3, yaw: float = 0.0, longest: bool = false) -> Node3D:
	var m := AS.instance_fitted(part, height, longest)
	if m == null:
		_missing[part] = true
		return null
	m.position = pos
	m.rotation.y = yaw
	level.add_child(m)
	var ap := AS.find_anim_player(m)
	if ap != null:
		var list := ap.get_animation_list()
		if list.size() > 0:
			var an: String = AS.anim_name(ap, "Idle")
			if an == "":
				an = list[0]
			var a := ap.get_animation(an)
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR
			ap.play(an)
	return m


# invisible solid box (layer 1 = world: blocks players, creatures AND interaction rays; layer 4 = blocks players only)
func _solid(pos: Vector3, size: Vector3, layer: int = 1, yaw: float = 0.0) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = layer
	b.collision_mask = 0
	b.position = pos
	b.rotation.y = yaw
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	b.add_child(cs)
	level.add_child(b)
	return b


func _label3d(text: String, pos: Vector3, yaw: float, color: Color, size: int = 64, shaded: bool = true) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.rotation.y = yaw
	l.modulate = color
	l.font_size = size
	l.pixel_size = 0.006
	l.shaded = shaded
	l.double_sided = true
	l.outline_size = 8
	level.add_child(l)
	return l


# ---------------------------------------------------------------- placement helpers (all use the seeded rng)

func _avoid_box(cx: float, cz: float, hx: float, hz: float) -> void:
	avoid.append(Rect2(cx - hx, cz - hz, hx * 2.0, hz * 2.0))


func _blocked(x: float, z: float, r: float) -> bool:
	for a in avoid:
		if (a as Rect2).grow(r).has_point(Vector2(x, z)):
			return true
	return false


func _free_spot(rng: RandomNumberGenerator, x0: float, x1: float, z0: float, z1: float, r: float = 0.7) -> Vector3:
	var p := Vector3.ZERO
	for t in range(30):
		p = Vector3(rng.randf_range(x0, x1), 0.0, rng.randf_range(z0, z1))
		if not _blocked(p.x, p.z, r):
			return p
	return p


# a spot hidden BEHIND a rock / pillar (the side away from the players' walking direction -z)
func _hide_behind(cx: float, cz: float, half_depth: float, ox: float = 0.0) -> void:
	hide_spots.append(Vector3(cx + ox, 0.0, cz - half_depth - 0.55))


func _shuffle(rng: RandomNumberGenerator, a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


# vases (first ones hidden behind rocks / pillars) and money bags inside a zone
func _scatter_loot(rng: RandomNumberGenerator, cave_id: int, x0: float, x1: float, z0: float, z1: float, n_pots: int, n_bags: int) -> void:
	var hs: Array = hide_spots.duplicate()
	_shuffle(rng, hs)
	var hidden_pots := ceili(float(n_pots) * 0.6)
	for i in range(n_pots):
		var p: Vector3
		if i < hidden_pots and not hs.is_empty():
			p = hs.pop_back()
		else:
			p = _free_spot(rng, x0, x1, z0, z1)
		_make_loot("pot", p, rng.randf() * TAU, cave_id)
		_avoid_box(p.x, p.z, 0.4, 0.4)
	for i in range(n_bags):
		var p: Vector3
		if i == 0 and not hs.is_empty() and rng.randf() < 0.5:
			p = hs.pop_back()
		else:
			p = _free_spot(rng, x0, x1, z0, z1)
		_make_loot("bag", p, rng.randf() * TAU, cave_id)
		_avoid_box(p.x, p.z, 0.4, 0.4)


# one gold chest at one of the candidate spots (random each run)
func _place_chest(rng: RandomNumberGenerator, cave_id: int, spots: Array, yaws: Array) -> void:
	var i := rng.randi_range(0, spots.size() - 1)
	var p: Vector3 = spots[i]
	_make_loot("chest", p, float(yaws[i]), cave_id)
	_avoid_box(p.x, p.z, 0.9, 0.9)


func _scatter_skulls(rng: RandomNumberGenerator, x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	for i in range(n):
		var p := _free_spot(rng, x0, x1, z0, z1, 0.4)
		_decor("Skull.fbx", 0.3, p, rng.randf() * TAU)


# cobwebs in the corners where the walls meet the ceiling
func _scatter_cobwebs(rng: RandomNumberGenerator, x_wall: float, z0: float, z1: float, h: float, n: int) -> void:
	for i in range(n):
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var z := rng.randf_range(z0, z1)
		var yaw := (PI / 2.0 if side < 0.0 else -PI / 2.0) + rng.randf_range(-0.3, 0.3)
		_decor("Cobweb2.fbx", 1.0, Vector3(side * (x_wall - 0.1), h - 1.0, z), yaw)


func _place_cart(pos: Vector3, yaw: float) -> void:
	var m := _decor("Cart.fbx", 1.5, pos, yaw, true)
	if m != null:
		_solid(pos + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.5), 1, yaw)
		_avoid_box(pos.x, pos.z, 0.9, 0.9)
		_hide_behind(pos.x, pos.z, 0.9)


func _candles(pos: Vector3, rng: RandomNumberGenerator) -> void:
	_decor("Candles_2.fbx", 0.35, pos, rng.randf() * TAU)
	LB.light(level, pos + Vector3(0, 0.6, 0), Color(1.0, 0.62, 0.3), 0.7, 3.2)


func _decorate_rocks(rng: RandomNumberGenerator, x0: float, x1: float, z0: float, z1: float, h: float, n: int) -> void:
	for i in range(n):
		var x := rng.randf_range(x0, x1)
		var z := rng.randf_range(z0, z1)
		var r := rng.randf_range(0.2, 0.6)
		var ln := rng.randf_range(0.8, 2.4)
		LB.rock_cone(level, x, z, h, r, ln, rock, false)      # stalactites hang from the ceiling (no problem for loot)
	for i in range(n):
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var x := (x0 if side < 0.0 else x1) + (0.5 if side < 0.0 else -0.5)
		var z := rng.randf_range(z0, z1)
		var r := rng.randf_range(0.3, 0.7)
		var ln := rng.randf_range(0.8, 2.0)
		if _blocked(x, z, 0.5):
			continue                                           # do not grow through bookcases / carts / chests
		LB.rock_cone(level, x, z, 0.0, r, ln, rock, true)


# ---------------------------------------------------------------- stage 2: cave dressing
# Decorative only: no collisions, no loot spots, no gameplay state. Every random value comes
# from _drng so the playable layout stays identical on all peers for a given seed.

func _xf(pos: Vector3, yaw := 0.0, scl := Vector3.ONE, tilt := Vector3.ZERO) -> Transform3D:
	var b := Basis.from_euler(Vector3(tilt.x, yaw, tilt.z))
	b = b.scaled(scl)
	return Transform3D(b, pos)


func _multimesh(mesh: Mesh, mat: Material, xforms: Array, colors: Array = [], shadows := false) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	if not colors.is_empty():
		mm.use_colors = true
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
		if not colors.is_empty():
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	level.add_child(mmi)
	return mmi


func _decor_spot(x0: float, x1: float, z0: float, z1: float, r: float) -> Vector3:
	for t in range(20):
		var p := Vector3(_drng.randf_range(x0, x1), 0.0, _drng.randf_range(z0, z1))
		if not _blocked(p.x, p.z, r):
			return p
	return Vector3(_drng.randf_range(x0, x1), 0.0, _drng.randf_range(z0, z1))


func _soft_dot() -> Texture2D:
	if _dot_tex != null:
		return _dot_tex
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_dot_tex = t
	return _dot_tex


func _particle_material(tint: Color, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _soft_dot()
	m.albedo_color = tint
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = tint
		m.emission_energy_multiplier = energy
	return m


func _particles(pos: Vector3, extents: Vector3, tint: Color, amount: int, lifetime: float,
		gravity: Vector3, vel_min: float, vel_max: float, scale_min: float, scale_max: float,
		energy := 0.0, spread := 180.0) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = minf(lifetime * 0.7, 8.0)
	p.fixed_fps = 30
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	p.position = pos
	p.direction = Vector3.UP
	p.spread = spread
	p.gravity = gravity
	p.initial_velocity_min = vel_min
	p.initial_velocity_max = vel_max
	p.scale_amount_min = scale_min
	p.scale_amount_max = scale_max
	p.color = tint
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	q.material = _particle_material(Color(1, 1, 1, 1), energy)
	p.mesh = q
	p.visibility_aabb = AABB(-extents - Vector3(1, 2, 1), extents * 2.0 + Vector3(2, 5, 2))
	level.add_child(p)
	return p


func _dust(x0: float, x1: float, z0: float, z1: float, h: float, tint: Color, amount := 36, energy := 0.0) -> void:
	_particles(Vector3((x0 + x1) * 0.5, h * 0.5, (z0 + z1) * 0.5),
		Vector3((x1 - x0) * 0.5 - 0.3, h * 0.42, (z1 - z0) * 0.5 - 0.3),
		tint, amount, 14.0, Vector3(0, -0.015, 0), 0.01, 0.06, 0.02, 0.055, energy)


func _embers(pos: Vector3, extents: Vector3, tint: Color, amount := 26) -> void:
	_particles(pos, extents, tint, amount, 3.2, Vector3(0, 0.9, 0), 0.25, 0.8, 0.02, 0.06, 2.2, 22.0)


func _drips(pos: Vector3, ceiling: float, count := 1) -> void:
	for i in range(count):
		var life := sqrt(2.0 * maxf(0.6, ceiling) / 12.0)
		var p := _particles(Vector3(pos.x + _drng.randf_range(-0.45, 0.45), ceiling - 0.1, pos.z + _drng.randf_range(-0.45, 0.45)),
			Vector3(0.1, 0.05, 0.1), Color(0.55, 0.7, 0.82, 0.85), 6, life,
			Vector3(0, -12.0, 0), 0.0, 0.2, 0.018, 0.03, 0.8, 0.0)
		p.direction = Vector3.DOWN
		p.preprocess = 0.0


func _puddles(x0: float, x1: float, z0: float, z1: float, n: int, y := 0.015) -> void:
	if x1 - x0 < 2.0 or z1 - z0 < 2.0:
		return
	var xf: Array = []
	for i in range(n):
		var s := _drng.randf_range(0.8, 2.8)
		var pos := Vector3(_drng.randf_range(x0 + 1.0, x1 - 1.0), y, _drng.randf_range(z0 + 1.0, z1 - 1.0))
		xf.append(_xf(pos, _drng.randf() * TAU, Vector3(s, 1.0, s * _drng.randf_range(0.55, 1.0))))
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	_multimesh(plane, water_mat, xf)


func _crystals(spots: Array, mat: Material, tall := 1.0) -> void:
	var xf: Array = []
	for sp in spots:
		var p: Vector3 = sp
		if _blocked(p.x, p.z, 0.5):
			continue
		var shards := _drng.randi_range(3, 6)
		for j in range(shards):
			var ln := _drng.randf_range(0.45, 1.5) * tall
			var rad := _drng.randf_range(0.10, 0.22)
			var off := Vector3(_drng.randf_range(-0.45, 0.45), ln * 0.5, _drng.randf_range(-0.45, 0.45))
			xf.append(_xf(p + off, _drng.randf() * TAU, Vector3(rad / 0.15, ln, rad / 0.15),
				Vector3(_drng.randf_range(-0.3, 0.3), 0.0, _drng.randf_range(-0.3, 0.3))))
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.15
	cone.height = 1.0
	cone.radial_segments = 5
	cone.rings = 1
	_multimesh(cone, mat, xf)


func _stalactites(x0: float, x1: float, z0: float, z1: float, h: float, n: int) -> void:
	var xf: Array = []
	for i in range(n):
		var ln := _drng.randf_range(0.4, 2.2)
		var rad := _drng.randf_range(0.5, 1.4)
		var p := Vector3(_drng.randf_range(x0, x1), h, _drng.randf_range(z0, z1))
		xf.append(_xf(p - Vector3(0, ln * 0.5, 0), _drng.randf() * TAU, Vector3(rad, ln, rad),
			Vector3(_drng.randf_range(-0.08, 0.08), 0.0, _drng.randf_range(-0.08, 0.08))))
	var cone := CylinderMesh.new()
	cone.top_radius = 0.15
	cone.bottom_radius = 0.0
	cone.height = 1.0
	cone.radial_segments = 6
	cone.rings = 1
	_multimesh(cone, rock, xf)


func _icicles(x0: float, x1: float, z0: float, z1: float, h: float, n: int) -> void:
	var xf: Array = []
	for i in range(n):
		var ln := _drng.randf_range(0.4, 1.7)
		var rad := _drng.randf_range(0.5, 1.3)
		var p := Vector3(_drng.randf_range(x0, x1), h, _drng.randf_range(z0, z1))
		xf.append(_xf(p - Vector3(0, ln * 0.5, 0), _drng.randf() * TAU, Vector3(rad, ln, rad)))
	var cone := CylinderMesh.new()
	cone.top_radius = 0.14
	cone.bottom_radius = 0.0
	cone.height = 1.0
	cone.radial_segments = 6
	cone.rings = 1
	_multimesh(cone, ice_mat, xf, [], true)


func _beams(x0: float, x1: float, z0: float, z1: float, ceiling: float, step: float) -> void:
	var xf: Array = []
	var z := z0 + step
	while z < z1 - step * 0.4:
		xf.append(_xf(Vector3((x0 + x1) * 0.5, ceiling - 0.35, z), 0.0, Vector3(x1 - x0, 1.0, 1.0)))
		z += step
	var b := BoxMesh.new()
	b.size = Vector3(1.0, 0.28, 0.3)
	_multimesh(b, bark_mat, xf, [], true)


func _books(x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	var xf: Array = []
	var cols: Array = []
	var palette := [Color(0.42, 0.08, 0.06), Color(0.10, 0.20, 0.35), Color(0.15, 0.28, 0.14), Color(0.35, 0.20, 0.08), Color(0.30, 0.28, 0.25)]
	for i in range(n):
		var p := Vector3(_drng.randf_range(x0, x1), 0.026, _drng.randf_range(z0, z1))
		xf.append(_xf(p, _drng.randf() * TAU, Vector3(_drng.randf_range(0.75, 1.2), 1.0, _drng.randf_range(0.8, 1.3))))
		cols.append(palette[_drng.randi_range(0, palette.size() - 1)])
	var b := BoxMesh.new()
	b.size = Vector3(0.34, 0.05, 0.24)
	_multimesh(b, book_mat, xf, cols)


func _barrels(x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	var xf: Array = []
	for i in range(n):
		var s := _drng.randf_range(0.8, 1.15)
		var spot := _decor_spot(x0, x1, z0, z1, 0.5)
		var p := Vector3(spot.x, 0.42 * s, spot.z)
		xf.append(_xf(p, _drng.randf() * TAU, Vector3(s, s, s)))
	var c := CylinderMesh.new()
	c.top_radius = 0.34
	c.bottom_radius = 0.34
	c.height = 0.84
	c.radial_segments = 10
	c.rings = 1
	_multimesh(c, bark_mat, xf)


func _crates(x0: float, x1: float, z0: float, z1: float, n: int, mat: Material = null) -> void:
	var xf: Array = []
	for i in range(n):
		var s := _drng.randf_range(0.65, 1.2)
		var spot := _decor_spot(x0, x1, z0, z1, 0.55)
		var p := Vector3(spot.x, 0.4 * s, spot.z)
		xf.append(_xf(p, _drng.randf() * TAU, Vector3(s, s, s)))
	var b := BoxMesh.new()
	b.size = Vector3(0.8, 0.8, 0.8)
	_multimesh(b, bark_mat if mat == null else mat, xf)


func _bones(x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	var xf: Array = []
	for i in range(n):
		var ln := _drng.randf_range(0.28, 0.9)
		var p := Vector3(_drng.randf_range(x0, x1), 0.055, _drng.randf_range(z0, z1))
		xf.append(_xf(p, _drng.randf() * TAU, Vector3(_drng.randf_range(0.7, 1.4), ln, _drng.randf_range(0.7, 1.4)),
			Vector3(PI / 2.0, 0.0, _drng.randf_range(-0.25, 0.25))))
	var c := CylinderMesh.new()
	c.top_radius = 0.035
	c.bottom_radius = 0.05
	c.height = 1.0
	c.radial_segments = 5
	c.rings = 1
	_multimesh(c, bone_mat, xf)


func _chains(x0: float, x1: float, z0: float, z1: float, ceiling: float, n: int) -> void:
	var xf: Array = []
	for i in range(n):
		var ln := _drng.randf_range(0.6, 2.2)
		var p := Vector3(_drng.randf_range(x0, x1), ceiling - ln * 0.5, _drng.randf_range(z0, z1))
		xf.append(_xf(p, 0.0, Vector3(1.0, ln, 1.0), Vector3(_drng.randf_range(-0.12, 0.12), 0.0, _drng.randf_range(-0.12, 0.12))))
	var c := CylinderMesh.new()
	c.top_radius = 0.02
	c.bottom_radius = 0.02
	c.height = 1.0
	c.radial_segments = 4
	c.rings = 1
	_multimesh(c, iron_mat, xf)


func _pipes(x0: float, x1: float, z0: float, z1: float, ceiling: float) -> void:
	var xf: Array = []
	for side in [-1.0, 1.0]:
		var x: float = (x1 - 0.55) * side
		for i in range(3):
			var z := _drng.randf_range(z0 + 3.0, z1 - 3.0)
			var ln := _drng.randf_range(10.0, 20.0)
			xf.append(_xf(Vector3(x, ceiling - 0.25 - i * 0.28, z), 0.0, Vector3(1.0, ln, 1.0), Vector3(PI / 2.0, 0.0, 0.0)))
	var c := CylinderMesh.new()
	c.top_radius = 0.10
	c.bottom_radius = 0.10
	c.height = 1.0
	c.radial_segments = 8
	c.rings = 1
	_multimesh(c, iron_mat, xf)
	# valve wheels on the wall side of the pipes
	var wheel_xf: Array = []
	for side in [-1.0, 1.0]:
		for i in range(2):
			var p := Vector3((x1 - 0.55) * side, ceiling - 0.65, _drng.randf_range(z0 + 4.0, z1 - 4.0))
			wheel_xf.append(_xf(p, 0.0, Vector3(0.32, 0.32, 0.32), Vector3(PI / 2.0, 0.0, 0.0)))
	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	_multimesh(tm, copper_mat, wheel_xf)


func _ruins(x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	var xf: Array = []
	var tops: Array = []
	for i in range(n):
		var side := -1.0 if _drng.randf() < 0.5 else 1.0
		var base := Vector3((x1 - 0.7) * side, 0.0, _drng.randf_range(z0 + 2.0, z1 - 2.0))
		if _blocked(base.x, base.z, 0.7):
			continue
		var hgt := _drng.randf_range(1.2, 4.2)
		var segs := _drng.randi_range(2, 4)
		for j in range(segs):
			var seg_h := hgt / float(segs)
			xf.append(_xf(base + Vector3(_drng.randf_range(-0.03, 0.03), seg_h * (j + 0.5), _drng.randf_range(-0.03, 0.03)),
				_drng.randf_range(-0.04, 0.04), Vector3(0.42, seg_h, 0.42)))
		if _drng.randf() < 0.7:
			tops.append(_xf(base + Vector3(0, hgt + 0.09, 0), _drng.randf() * TAU, Vector3(0.55, 0.18, 0.55),
				Vector3(_drng.randf_range(-0.2, 0.2), 0.0, _drng.randf_range(-0.2, 0.2))))
		# a fallen drum section on the floor beside it
		if _drng.randf() < 0.55:
			var ln := _drng.randf_range(0.9, 2.2)
			xf.append(_xf(base + Vector3(-side * _drng.randf_range(1.0, 2.2), 0.36, _drng.randf_range(-1.5, 1.5)),
				_drng.randf() * TAU, Vector3(0.34, ln, 0.34), Vector3(PI / 2.0, 0.0, 0.0)))
	var col := CylinderMesh.new()
	col.top_radius = 1.0
	col.bottom_radius = 1.0
	col.height = 1.0
	col.radial_segments = 10
	col.rings = 1
	_multimesh(col, rock, xf)
	if not tops.is_empty():
		var cap := BoxMesh.new()
		cap.size = Vector3.ONE
		_multimesh(cap, rock, tops)


func _mushrooms(spots: Array, cap_mat: Material, scale := 1.0) -> void:
	var stems: Array = []
	var caps: Array = []
	for sp in spots:
		var base: Vector3 = sp
		if _blocked(base.x, base.z, 0.4):
			continue
		for j in range(_drng.randi_range(2, 5)):
			var p := base + Vector3(_drng.randf_range(-0.55, 0.55), 0.0, _drng.randf_range(-0.55, 0.55))
			var s := _drng.randf_range(0.6, 1.5) * scale
			var hgt := 0.28 * s
			stems.append(_xf(p + Vector3(0, hgt * 0.5, 0), 0.0, Vector3(s, hgt, s)))
			caps.append(_xf(p + Vector3(0, hgt, 0), _drng.randf() * TAU, Vector3(s, s, s)))
	var stem := CylinderMesh.new()
	stem.top_radius = 0.035
	stem.bottom_radius = 0.05
	stem.height = 1.0
	stem.radial_segments = 5
	stem.rings = 1
	_multimesh(stem, LB.material(Color(0.55, 0.5, 0.4)), stems)
	var cap := SphereMesh.new()
	cap.radius = 0.28
	cap.height = 0.18
	cap.radial_segments = 8
	cap.rings = 4
	_multimesh(cap, cap_mat, caps)


func _chandelier(pos: Vector3, ceiling: float) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.75
	tm.outer_radius = 0.95
	tm.material = iron_mat
	ring.mesh = tm
	ring.position = pos + Vector3(0, ceiling - 1.3, 0)
	ring.rotation_degrees.x = 90.0
	level.add_child(ring)
	for i in range(6):
		var a := TAU * float(i) / 6.0
		var p := pos + Vector3(cos(a) * 0.85, ceiling - 1.3, sin(a) * 0.85)
		var w := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.035
		cm.bottom_radius = 0.035
		cm.height = 0.22
		cm.radial_segments = 5
		cm.material = LB.material(Color(0.9, 0.86, 0.75))
		w.mesh = cm
		w.position = p + Vector3(0, 0.16, 0)
		level.add_child(w)
		var f := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.05
		sm.height = 0.1
		sm.material = LB.material(Color(1.0, 0.7, 0.3), 3.0)
		f.mesh = sm
		f.position = p + Vector3(0, 0.32, 0)
		level.add_child(f)
	LB.light(level, pos + Vector3(0, ceiling - 1.0, 0), Color(1.0, 0.72, 0.4), 0.8, 7.0)


func _dress_lobby() -> void:
	_dust(-11.5, 11.5, -11.5, 11.5, 6.0, Color(1.0, 0.85, 0.62, 0.45), 34)
	_chandelier(Vector3(0, 0, 0), 6.0)
	_decor("tattered-warning-banner", 3.6, Vector3(-11.4, 0.0, -8.0), PI / 2.0)
	_decor("tattered-warning-banner", 3.6, Vector3(11.4, 0.0, -8.0), -PI / 2.0)
	_crates(-11.2, -9.2, 8.0, 10.5, 3)
	_crates(9.2, 11.2, -11.0, -8.5, 2)
	_barrels(-11.2, -10.0, 7.0, 9.5, 2)


func _dress_cave1() -> void:
	var h := 5.0
	_dust(-4.6, 4.6, -69.0, -31.0, h, Color(0.95, 0.9, 0.78, 0.38), 32)
	_beams(-5.0, 5.0, -70.0, -30.0, h, 7.5)
	_books(-4.5, -2.7, -68.0, -32.0, 16)
	_books(2.7, 4.5, -68.0, -32.0, 16)
	_barrels(-4.6, -3.5, -68.0, -34.0, 3)
	_barrels(3.5, 4.6, -68.0, -34.0, 3)
	_crates(-4.5, -3.3, -66.0, -34.0, 3)
	_crates(3.3, 4.5, -66.0, -34.0, 3)
	_puddles(-4.4, 4.4, -68.0, -32.0, 5)
	_stalactites(-4.8, 4.8, -69.0, -31.0, h, 16)
	_drips(Vector3(-2.2, 0.0, -51.0), h, 1)
	_drips(Vector3(2.4, 0.0, -63.0), h, 1)


func _dress_cave2() -> void:
	var h := 6.0
	_dust(-8.5, 8.5, -119.0, -71.0, h, Color(0.62, 0.85, 0.92, 0.3), 38)
	_ruins(-8.8, 8.8, -119.0, -71.0, 9)
	_puddles(-7.8, 7.8, -118.0, -72.0, 8)
	_bones(-7.0, 7.0, -118.0, -72.0, 16)
	_stalactites(-8.5, 8.5, -119.0, -71.0, h, 20)
	var cs: Array = []
	for z in [-78.0, -88.0, -99.0, -110.0]:
		cs.append(Vector3(-7.9, 0.0, z))
		cs.append(Vector3(7.9, 0.0, z))
	_crystals(cs, crystal_teal, 0.9)
	LB.light(level, Vector3(-7.6, 1.0, -88.0), Color(0.3, 0.9, 1.0), 0.8, 4.5)
	LB.light(level, Vector3(7.6, 1.0, -110.0), Color(0.3, 0.9, 1.0), 0.8, 4.5)
	_drips(Vector3(0.0, 0.0, -84.0), h, 1)
	_drips(Vector3(1.5, 0.0, -106.0), h, 1)


func _dress_cave3() -> void:
	var h := 5.0
	_dust(-5.5, 5.5, -189.0, -121.0, h, Color(0.72, 0.73, 0.78, 0.3), 34)
	_pipes(-5.0, 5.0, -190.0, -120.0, h)
	_chains(-4.4, 4.4, -186.0, -124.0, h, 10)
	_crates(-4.7, -3.4, -187.0, -124.0, 5, iron_mat)
	_crates(3.4, 4.7, -187.0, -124.0, 5, iron_mat)
	_barrels(-4.7, -3.5, -184.0, -126.0, 2)
	_puddles(-4.5, 4.5, -188.0, -122.0, 6)
	_stalactites(-5.2, 5.2, -189.0, -121.0, h, 14)
	_embers(Vector3(-2.0, 0.2, -150.0), Vector3(0.4, 0.1, 0.4), Color(1.0, 0.5, 0.2, 1.0), 10)
	_drips(Vector3(0.0, 0.0, -160.0), h, 1)


func _dress_cave4() -> void:
	var h := 6.0
	_dust(-7.5, 7.5, -258.0, -192.0, h, Color(0.65, 0.8, 1.0, 0.32), 36)
	_bones(-6.5, 6.5, -256.0, -196.0, 30)
	_puddles(-7.2, 7.2, -256.0, -194.0, 7)
	_stalactites(-7.8, 7.8, -258.0, -192.0, h, 18)
	_icicles(-7.8, 7.8, -258.0, -192.0, h - 0.2, 16)
	var cs: Array = []
	for z in [-202.0, -214.0, -226.0, -238.0, -250.0]:
		cs.append(Vector3(-7.6, 0.0, z))
		cs.append(Vector3(7.6, 0.0, z))
	_crystals(cs, crystal_teal, 0.8)
	LB.light(level, Vector3(-7.4, 1.0, -226.0), Color(0.35, 0.75, 1.0), 0.8, 5.0)
	LB.light(level, Vector3(7.4, 1.0, -250.0), Color(0.35, 0.75, 1.0), 0.8, 5.0)
	_decor("tattered-warning-banner", 3.6, Vector3(-7.5, 0.0, -220.0), PI / 2.0)
	_decor("tattered-warning-banner", 3.6, Vector3(7.5, 0.0, -244.0), -PI / 2.0)
	_bones(-4.0, 3.0, -252.0, -246.0, 10)
	_drips(Vector3(-2.5, 0.0, -208.0), h, 1)
	_drips(Vector3(2.0, 0.0, -232.0), h, 1)


func _dress_cave5() -> void:
	var h := 7.0
	_dust(-8.5, 8.5, -316.0, -264.0, h, Color(0.68, 0.52, 1.0, 0.42), 44, 0.8)
	var violet: Array = []
	var teal: Array = []
	var mus: Array = []
	for i in range(7):
		var z := -268.0 - i * 7.0
		var side := -1.0 if i % 2 == 0 else 1.0
		violet.append(Vector3(side * 8.1, 0.0, z))
		teal.append(Vector3(-side * 8.1, 0.0, z - 3.0))
		mus.append(Vector3(-side * 7.2, 0.0, z + 1.5))
	_crystals(violet, crystal_violet, 1.1)
	_crystals(teal, crystal_teal, 0.9)
	_mushrooms(mus, crystal_violet, 1.2)
	_puddles(-7.5, 7.5, -316.0, -266.0, 6)
	_stalactites(-8.8, 8.8, -318.0, -264.0, h, 22)
	_icicles(-8.8, 8.8, -318.0, -264.0, h - 0.2, 8)
	_bones(-7.0, 7.0, -316.0, -268.0, 10)
	_embers(Vector3(-6.5, 0.25, -334.0), Vector3(2.2, 0.15, 2.6), Color(1.0, 0.4, 0.12, 1.0), 26)
	_drips(Vector3(3.0, 0.0, -300.0), h, 1)
	LB.light(level, Vector3(-7.2, 1.2, -292.0), Color(0.7, 0.4, 1.0), 1.0, 5.5)
	LB.light(level, Vector3(7.2, 1.2, -278.0), Color(0.3, 0.9, 1.0), 0.9, 5.0)


# ---------------------------------------------------------------- lobby

func _build_lobby(rng: RandomNumberGenerator) -> void:
	var h := 6.0
	_floor(-13.0, 13.0, -13.0, 13.0)
	_ceil(-13.0, 13.0, -13.0, 13.0, h)
	_wall_side(-12.0, -1.0, -13.0, 13.0, h)
	_wall_side(12.0, 1.0, -13.0, 13.0, h)
	_wall_front(-12.0, -1.0, -12.0, 12.0, h)
	_wall_front(12.0, 1.0, -12.0, 12.0, h)
	for p in [Vector3(-10, 3.2, -10), Vector3(10, 3.2, -10), Vector3(-10, 3.2, 10), Vector3(10, 3.2, 10)]:
		LB.light(level, p, Color(1.0, 0.7, 0.4), 1.6, 14.0)
	LB.light(level, Vector3(0, 4.5, 0), Color(1.0, 0.85, 0.6), 1.0, 16.0)
	# pillars
	var pillar := LB.rock_material(Color(0.5, 0.45, 0.4), 0.3)
	for px in [-6.0, 6.0]:
		for pz in [-4.0, 4.0]:
			LB.box(level, px - 0.5, px + 0.5, 0.0, h, pz - 0.5, pz + 0.5, pillar)
	# carpet tiles leading to the portal
	for i in range(5):
		for j in range(2):
			var t := _decor("patterned-casino-carpet-tile", 2.0, Vector3(-1.0 + j * 2.0, 0.02, 8.0 - i * 2.0), 0.0, true)
			if t != null:
				t.rotation_degrees.x = 0.0
	# cave mouth behind the portal + the yellow portal
	_decor("smuggler-cave-mouth", 5.0, Vector3(0, 0, -11.4), PI)
	_build_yellow_portal(Vector3(0, 0, -9.6))
	# the two stations: Skin Changer (left) and Role Changer (right)
	_build_skin_station(Vector3(-9.0, 0, -7.0))
	_build_role_station(Vector3(9.0, 0, -7.0))
	# decoration
	for pos in [Vector3(-11, 0, 11), Vector3(11, 0, 11), Vector3(-11, 0, -2), Vector3(11, 0, -2)]:
		_decor("colonial-lamp-post", 3.2, pos, 0.0)
		LB.light(level, pos + Vector3(0, 3.0, 0), Color(1, 0.8, 0.5), 0.8, 7.0)
	_decor("tattered-warning-banner", 3.6, Vector3(-11.4, 0.0, 3.0), PI / 2.0)
	_decor("tattered-warning-banner", 3.6, Vector3(11.4, 0.0, 3.0), -PI / 2.0)
	_decor("wanted-poster-board", 2.2, Vector3(-11.0, 0, 6.5), PI / 2.0)
	_decor("wanted-poster-board", 2.2, Vector3(11.0, 0, 6.5), -PI / 2.0)
	_decor("wheeled-easel-board", 2.0, Vector3(7.0, 0, -2.5), -0.5)
	_decor("paper-stack", 0.12, Vector3(6.2, 0.0, -4.2), 0.4)
	_decor("glass-door-drinks-fridge", 2.0, Vector3(11.0, 0, -9.5), -PI / 2.0)
	_decor("meter-box", 0.8, Vector3(11.7, 1.4, 1.0), -PI / 2.0)
	_decor("cable-spaghetti-bundle", 0.3, Vector3(-7.5, 0.0, 9.0), 0.8)
	_decor("lefthand-item", 0.4, Vector3(-9.0, 1.05, -4.5), 0.3)
	_decor("dog-base", 0.7, Vector3(3.5, 0, 7.0), -2.4)
	_decor("Candles_2.fbx", 0.35, Vector3(-3.0, 0.0, -10.5), 0.5)
	_decor("Candles_2.fbx", 0.35, Vector3(3.0, 0.0, -10.5), 2.0)
	# plants (leaf texture)
	var leaf := AS.load_texture("Leaf_Texture")
	if leaf != null:
		for pos in [Vector3(-11, 0.7, -11), Vector3(11, 0.7, -11), Vector3(-4, 0.7, 11.3), Vector3(4, 0.7, 11.3)]:
			var sp := Sprite3D.new()
			sp.texture = leaf
			sp.pixel_size = 0.0045
			sp.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
			sp.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
			sp.position = pos
			level.add_child(sp)
	_dress_lobby()


func _build_yellow_portal(pos: Vector3) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 1.3
	tm.outer_radius = 1.7
	tm.material = LB.material(Color(1, 0.85, 0.1), 2.0)
	ring.mesh = tm
	ring.position = pos + Vector3(0, 1.9, 0)
	ring.rotation_degrees.x = 90.0
	level.add_child(ring)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.35
	cm.bottom_radius = 1.35
	cm.height = 0.04
	var dm := LB.material(Color(1, 0.8, 0.1, 0.55), 1.2)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.material = dm
	disc.mesh = cm
	disc.position = pos + Vector3(0, 1.9, 0)
	disc.rotation_degrees.x = 90.0
	level.add_child(disc)
	LB.light(level, pos + Vector3(0, 2.0, 1.0), Color(1, 0.85, 0.2), 2.5, 9.0)
	_label3d("PORTAL", pos + Vector3(0, 4.0, 0.2), 0.0, Color(1, 0.9, 0.3), 70, false)
	if not Engine.is_editor_hint():
		var a := LB.area(level, pos.x - 1.4, pos.x + 1.4, 0.0, 3.8, pos.z - 0.6, pos.z + 0.6, _on_portal)
		a.name = "LobbyPortal"


func _build_skin_station(pos: Vector3) -> void:
	LB.box(level, pos.x - 0.9, pos.x + 0.9, 0.0, 0.5, pos.z - 0.9, pos.z + 0.9, LB.material(Color(0.2, 0.2, 0.25)))
	var mirror := LB.material(Color(0.3, 0.8, 1.0), 1.4)
	LB.box(level, pos.x - 0.6, pos.x + 0.6, 0.5, 2.6, pos.z - 0.12, pos.z + 0.12, mirror, false)
	LB.light(level, pos + Vector3(0, 2.0, 1.2), Color(0.4, 0.85, 1.0), 1.6, 6.0)
	_label3d("SKIN CHANGER", pos + Vector3(0, 3.1, 0.2), 0.0, Color(0.5, 0.9, 1.0), 56, false)
	_add_interact("skin", pos, 2.6, "Press E - Skin Changer", 0)


# Role Changer on the right side: decides who is Blind and who is Sighted (applied when the run starts)
func _build_role_station(pos: Vector3) -> void:
	LB.box(level, pos.x - 0.9, pos.x + 0.9, 0.0, 0.5, pos.z - 0.9, pos.z + 0.9, LB.material(Color(0.25, 0.18, 0.18)))
	var panel := LB.material(Color(1.0, 0.35, 0.3), 1.4)
	LB.box(level, pos.x - 0.6, pos.x + 0.6, 0.5, 2.6, pos.z - 0.12, pos.z + 0.12, panel, false)
	LB.light(level, pos + Vector3(0, 2.0, 1.2), Color(1.0, 0.5, 0.4), 1.6, 6.0)
	_label3d("ROLE CHANGER", pos + Vector3(0, 3.1, 0.2), 0.0, Color(1.0, 0.6, 0.5), 56, false)
	_decor("Skull.fbx", 0.3, pos + Vector3(0.55, 0.5, 0.55), -0.6)
	_add_interact("roles", pos, 2.6, "Press E - Role Changer (who is Blind?)", 0)


# ---------------------------------------------------------------- cave 1: training (library)

func _place_bookcase(rng: RandomNumberGenerator, side: float, z: float, cave_id: int) -> void:
	var pos := Vector3(side * 4.7, 0.0, z)
	var yaw := (PI / 2.0) if side < 0.0 else (-PI / 2.0)       # the back of the case against the wall
	var m := AS.instance_fitted("Bookcase_Full.fbx", BOOKCASE_H)
	if m != null:
		m.position = pos
		m.rotation.y = yaw
		level.add_child(m)
	else:
		_missing["Bookcase_Full.fbx"] = true
		var wood := LB.material(Color(0.35, 0.22, 0.12))
		var fb := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.9, BOOKCASE_H, 0.55)
		bm.material = wood
		fb.mesh = bm
		fb.position = pos + Vector3(0, BOOKCASE_H / 2.0, 0)
		fb.rotation.y = yaw
		level.add_child(fb)
	_solid(pos + Vector3(0, BOOKCASE_H / 2.0, 0), Vector3(1.95, BOOKCASE_H, 0.6), 4, yaw)   # layer 4: players can't walk through, rays reach the shelves
	_avoid_box(pos.x, pos.z, 0.5, 1.15)
	# random free shelf spots, random item (money bag or coin pile) each run
	var slots: Array = SHELF_SLOTS.duplicate()
	_shuffle(rng, slots)
	for i in range(LOOT_PER_BOOKCASE):
		var sl: Array = slots[i]
		var lp := Vector3(float(sl[0]) * BOOKCASE_SCALE, (float(SHELF_FLOOR[int(sl[1])]) + float(sl[2])) * BOOKCASE_SCALE, 0.0)
		var wp := pos + Basis(Vector3.UP, yaw) * lp
		var kind := "bag" if rng.randf() < 0.5 else "pile"
		_make_loot(kind, wp, rng.randf() * TAU, cave_id, {"mul": 0.62})
	_candles(pos + Basis(Vector3.UP, yaw) * Vector3(1.25, 0.0, 0.1), rng)


func _on_spikes(body: Node3D) -> void:
	if running and body == local_player and not local_player.frozen:
		Sfx.play("scare")
		local_player.rpc_damage(1000.0)


func _build_cave1(rng: RandomNumberGenerator) -> void:
	var h := 5.0
	hide_spots.clear()
	_hall(-5.0, 5.0, -70.0, -30.0, h)
	_end_wall(-30.0, -6.0, 6.0, h, 0.0, 0.0, 0.0)
	_end_wall(-70.0, -10.0, 10.0, h, 0.0, 3.2, 3.6)
	_make_door(1, 0.0, -70.0, 3.2, 3.6)
	# 4 bookcases at random places along the walls (never overlapping)
	var placed: Array = []
	var tries := 0
	while placed.size() < 4 and tries < 300:
		tries += 1
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var z := rng.randf_range(-64.0, -38.0)
		var ok := true
		for p in placed:
			if p[0] == side and absf(float(p[1]) - z) < 2.8:
				ok = false
		if ok:
			placed.append([side, z])
	for p in placed:
		_place_bookcase(rng, float(p[0]), float(p[1]), 1)
	_decorate_rocks(rng, -5.0, 5.0, -68.0, -32.0, h, 16)
	# solid rock blocks (also hiding spots for vases)
	for i in range(3):
		var bx := rng.randf_range(-3.2, 3.2)
		var bz := -42.0 - i * 9.0
		var byaw := rng.randf() * PI
		LB.rock_block(level, Vector3(bx, 0.4, bz), Vector3(1.2, 0.8, 1.2), byaw, rock)
		_solid(Vector3(bx, 0.4, bz), Vector3(1.2, 0.8, 1.2), 1, byaw)
		_avoid_box(bx, bz, 0.9, 0.9)
		_hide_behind(bx, bz, 0.9, rng.randf_range(-0.2, 0.2))
	# spike traps: the sighted players must guide the blind one around them
	for sp in [[-5.0, 0.8, -47.0, -44.6], [-0.8, 5.0, -56.0, -53.6], [-5.0, 1.5, -65.0, -62.6]]:
		LB.spikes(level, sp[0], sp[1], sp[2], sp[3], _on_spikes)
		_avoid_box((sp[0] + sp[1]) / 2.0, (sp[2] + sp[3]) / 2.0, absf(sp[1] - sp[0]) / 2.0 + 0.3, 1.5)
	_scatter_loot(rng, 1, -3.8, 3.8, -66.0, -36.0, 2, 1)
	_scatter_loot(rng, 1, -3.8, 3.8, -68.0, -38.0, 2, 1)
	_decor("wanted-poster-board", 2.0, Vector3(-4.5, 0, -38.0), PI / 2.0)
	_decor("cable-spaghetti-bundle", 0.3, Vector3(3.0, 0.0, -50.0), 0.4)
	_scatter_skulls(rng, -3.8, 3.8, -66.0, -34.0, 4)
	_scatter_cobwebs(rng, 5.0, -66.0, -34.0, h, 4)
	LB.light(level, Vector3(0, 3.5, -33.0), Color(1, 0.75, 0.45), 1.0, 8.0)
	_dress_cave1()


# ---------------------------------------------------------------- cave 2: the code (crypt)

func _build_cave2(rng: RandomNumberGenerator) -> void:
	var h := 6.0
	hide_spots.clear()
	_hall(-9.0, 9.0, -120.0, -70.0, h)
	_end_wall(-120.0, -10.0, 10.0, h, 0.0, 3.2, 3.6)
	_make_door(2, 0.0, -120.0, 3.2, 3.6)
	# the coloured plaques and the keypad are placed first, so nothing is put on top of them
	# 8 candidate wall spots (both sides, near and far): 4 are picked at random each run
	var cand: Array = []
	for cz in [-80.0, -90.0, -100.0, -110.0]:
		cand.append([Vector3(-8.4, 1.9, cz), PI / 2.0])
		cand.append([Vector3(8.4, 1.9, cz + 4.0), -PI / 2.0])
	_shuffle(rng, cand)
	for c in cand:
		_avoid_box((c[0] as Vector3).x, (c[0] as Vector3).z, 1.4, 1.6)
	_avoid_box(-3.0, -118.5, 2.0, 1.5)
	_decorate_rocks(rng, -9.0, 9.0, -118.0, -72.0, h, 22)
	for i in range(7):
		var px := rng.randf_range(-6.5, 6.5)
		var pz := -78.0 - i * 5.5
		LB.box(level, px - 0.6, px + 0.6, 0.0, h, pz - 0.6, pz + 0.6, rock)
		_avoid_box(px, pz, 0.6, 0.6)
		_hide_behind(px, pz, 0.6, rng.randf_range(-0.25, 0.25))
	# coloured plaques: colour = digit
	var spots: Array = cand.slice(0, 4)
	for i in range(4):
		var p: Vector3 = spots[i][0]
		var yaw: float = spots[i][1]
		_label3d("%s = %d" % [code_names[i], code_digits[i]], p, yaw, code_colors[i], 80, true)
		var lp := p + Vector3(-1.0 if yaw < 0.0 else 1.0, 0.0, 0.0)
		LB.light(level, lp, code_colors[i], 0.9, 3.2)
		if i < 2:
			# a vase stands in front of this plaque: smash it (hit it) to read the digit properly
			var vp := Vector3(p.x + (1.1 if yaw > 0.0 else -1.1), 0.0, p.z)
			_make_loot("pot", vp, rng.randf() * TAU, 2)
	# keypad next to the door
	var kp_pos := Vector3(-3.0, 1.3, -119.3)
	_decor("numeric-keypad", 0.5, kp_pos - Vector3(0, 0.25, 0), PI)
	LB.light(level, kp_pos + Vector3(0, 0.6, 1.0), Color(0.5, 1.0, 0.6), 1.0, 4.0)
	_label3d("KEYPAD", kp_pos + Vector3(0, 0.7, 0.1), 0.0, Color(0.6, 1, 0.7), 48, true)
	_add_interact("keypad", kp_pos, 2.6, "Press E - Keypad", 2)
	# gold chest (1 in this cave) against a wall, random spot each run
	_place_chest(rng, 2,
		[Vector3(-8.1, 0, -96.0), Vector3(8.1, 0, -87.0), Vector3(-8.1, 0, -76.0), Vector3(8.1, 0, -108.0)],
		[PI / 2.0, -PI / 2.0, PI / 2.0, -PI / 2.0])
	_place_cart(Vector3(7.6, 0.0, -112.0), PI / 2.0 + 0.2)
	_scatter_loot(rng, 2, -7.5, 7.5, -116.0, -74.0, 4, 2)
	_scatter_loot(rng, 2, -7.5, 7.5, -116.0, -74.0, 3, 2)
	_decor("paper-stack", 0.12, Vector3(2.0, 0.0, -112.0), 0.7)
	_decor("wanted-poster-board", 2.0, Vector3(8.2, 0, -90.0), -PI / 2.0)
	_scatter_skulls(rng, -7.5, 7.5, -116.0, -74.0, 6)
	_scatter_cobwebs(rng, 9.0, -116.0, -74.0, h, 6)
	_candles(Vector3(-7.4, 0.0, -90.5), rng)
	_candles(Vector3(7.4, 0.0, -101.0), rng)
	_dress_cave2()


# ---------------------------------------------------------------- cave 3: generators (4 corridors, 4 generators)

# one side corridor (sgn = -1 left / +1 right) centred on z = zc, with a generator at its end
func _corridor(sgn: float, zc: float, h: float, index: int, rng: RandomNumberGenerator) -> void:
	var xe := CORRIDOR_END
	var xa := 5.0 * sgn
	var xb := (xe + 1.0) * sgn
	LB.box(level, xa, xb, -1.0, 0.0, zc - 5.0, zc + 5.0, floor_mat)
	LB.box(level, xa, xb, h, h + 1.0, zc - 5.0, zc + 5.0, rock)
	LB.box(level, xa, xb, 0.0, h, zc + 4.0, zc + 5.0, rock)
	LB.box(level, xa, xb, 0.0, h, zc - 5.0, zc - 4.0, rock)
	LB.box(level, xe * sgn, xb, 0.0, h, zc - 5.0, zc + 5.0, rock)
	# the generator: its control door (+x side of the model) faces the corridor
	var gx := (xe - 1.2) * sgn
	var gyaw := PI if sgn > 0.0 else 0.0
	_decor("site-generator", 1.7, Vector3(gx, 0.0, zc), gyaw)
	_solid(Vector3(gx, 0.85, zc), Vector3(2.2, 1.7, 1.1), 1)
	_avoid_box(gx, zc, 1.3, 0.8)
	# status light on top: red = idle, yellow = held, green = powered
	var lamp := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.1
	cm.bottom_radius = 0.16
	cm.height = 0.26
	lamp.mesh = cm
	lamp.material_override = LB.material(Color(1, 0.15, 0.1), 2.0)
	lamp.position = Vector3(gx, 1.85, zc)
	level.add_child(lamp)
	var gl := LB.light(level, Vector3(gx - 1.6 * sgn, 2.0, zc), Color(1, 0.15, 0.1), 1.2, 6.5)
	gens.append({"lamp": lamp, "light": gl})
	_label3d("GENERATOR %d" % (index + 1), Vector3(gx - 1.4 * sgn, 2.7, zc), (PI / 2.0 if sgn < 0.0 else -PI / 2.0), Color(1, 0.8, 0.4), 50, true)
	_add_interact("gen_%d" % index, Vector3((xe - 3.8) * sgn, 0.0, zc), 3.0, "Hold E - Generator %d  (all 4 players together)" % (index + 1), 3, true)
	# corridor dressing and loot
	_hide_behind(gx, zc, 0.0, 0.0)
	hide_spots.append(Vector3((xe - 0.9) * sgn, 0.0, zc + 3.1))
	hide_spots.append(Vector3((xe - 0.9) * sgn, 0.0, zc - 3.1))
	_candles(Vector3((xe - 1.0) * sgn, 0.0, zc + 2.6), rng)
	_scatter_skulls(rng, minf(8.0 * sgn, 18.0 * sgn), maxf(8.0 * sgn, 18.0 * sgn), zc - 3.0, zc + 3.0, 2)
	if rng.randf() < 0.6:
		var p: Vector3 = hide_spots[hide_spots.size() - 1 - rng.randi_range(0, 1)]
		_make_loot("pot", p, rng.randf() * TAU, 3)
		_avoid_box(p.x, p.z, 0.4, 0.4)
	if rng.randf() < 0.5:
		var bp := _free_spot(rng, minf(7.0 * sgn, 15.0 * sgn), maxf(7.0 * sgn, 15.0 * sgn), zc - 3.0, zc + 3.0)
		_make_loot("bag", bp, rng.randf() * TAU, 3)
		_avoid_box(bp.x, bp.z, 0.4, 0.4)


func _build_cave3(rng: RandomNumberGenerator) -> void:
	var h := 5.0
	hide_spots.clear()
	var gaps: Array = []
	for zc in [CORRIDOR_ZS[1], CORRIDOR_ZS[0]]:          # sorted by z (ascending)
		gaps.append(Vector3(zc - 4.0, zc + 4.0, h))
	_floor(-6.0, 6.0, -190.5, -119.5)
	_ceil(-6.0, 6.0, -190.5, -119.5, h)
	_wall_side(-5.0, -1.0, -190.5, -119.5, h, gaps)
	_wall_side(5.0, 1.0, -190.5, -119.5, h, gaps)
	_end_wall(-190.0, -10.0, 10.0, h, 0.0, 3.2, 3.6)
	_make_door(3, 0.0, -190.0, 3.2, 3.6)
	var idx := 0
	for sgn in [-1.0, 1.0]:
		for zc in CORRIDOR_ZS:
			_corridor(sgn, zc, h, idx, rng)
			idx += 1
	LB.light(level, Vector3(0, 3.8, -130.0), Color(1, 0.6, 0.35), 1.0, 9.0)
	LB.light(level, Vector3(0, 3.8, -155.0), Color(1, 0.6, 0.35), 1.0, 9.0)
	_decorate_rocks(rng, -5.0, 5.0, -188.0, -122.0, h, 12)
	_place_cart(Vector3(-3.9, 0.0, -128.0), PI / 2.0)
	_place_cart(Vector3(3.9, 0.0, -184.0), -PI / 2.0 + 0.15)
	_scatter_loot(rng, 3, -3.5, 3.5, -186.0, -126.0, 1, 1)
	_scatter_loot(rng, 3, -3.5, 3.5, -186.0, -126.0, 2, 1)
	_decor("cable-spaghetti-bundle", 0.3, Vector3(1.5, 0.0, -150.0), 1.2)
	_decor("cable-spaghetti-bundle", 0.3, Vector3(-12.0, 0.0, -170.0), 0.2)
	_scatter_skulls(rng, -3.5, 3.5, -186.0, -126.0, 4)
	_scatter_cobwebs(rng, 5.0, -186.0, -124.0, h, 4)
	_dress_cave3()


# ---------------------------------------------------------------- cave 4: the wolf

func _build_cave4(rng: RandomNumberGenerator) -> void:
	var h := 6.0
	hide_spots.clear()
	_hall(-8.0, 8.0, -260.0, -190.0, h)
	_end_wall(-260.0, -10.0, 10.0, h, 0.0, 3.2, 3.6)
	_make_door(4, 0.0, -260.0, 3.2, 3.6)
	# rocks to hide behind (also hiding places for vases and the chest)
	var rock_spots: Array = []
	var rock_yaws: Array = []
	for i in range(8):
		var rx := rng.randf_range(-6.0, 6.0)
		var rz := -202.0 - i * 7.0
		LB.box(level, rx - 1.0, rx + 1.0, 0.0, 1.6, rz - 0.8, rz + 0.8, rock)
		_avoid_box(rx, rz, 1.0, 0.8)
		_hide_behind(rx, rz, 0.8, rng.randf_range(-0.3, 0.3))
		if i >= 3:
			rock_spots.append(hide_spots[hide_spots.size() - 1])
			rock_yaws.append(rng.randf() * TAU)
	_decorate_rocks(rng, -8.0, 8.0, -258.0, -192.0, h, 20)
	# the gold chest hides behind one of the far rocks
	_place_chest(rng, 4, rock_spots, rock_yaws)
	# stones to pick up
	for i in range(6):
		var sp := Vector3(rng.randf_range(-6.5, 6.5), 0.15, -198.0 - i * 9.5)
		var m := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.15
		sm.height = 0.3
		sm.material = LB.material(Color(0.55, 0.55, 0.58), 0.3)
		m.mesh = sm
		m.position = sp
		level.add_child(m)
		_add_interact("stone_%d" % i, sp, 1.8, "Press E - Pick up stone", 4, false, m)
	# den dressing: prison cells along the walls, carts, bones
	_decor("barred-cell-door", 2.2, Vector3(-7.45, 0.0, -214.0), PI / 2.0)
	_decor("barred-cell-door", 2.2, Vector3(7.45, 0.0, -236.0), -PI / 2.0)
	_place_cart(Vector3(-7.0, 0.0, -224.0), PI / 2.0 - 0.2)
	_place_cart(Vector3(7.0, 0.0, -204.0), -PI / 2.0)
	_scatter_loot(rng, 4, -6.5, 6.5, -256.0, -196.0, 3, 2)
	_scatter_loot(rng, 4, -6.5, 6.5, -256.0, -196.0, 3, 2)
	_scatter_skulls(rng, -6.5, 6.5, -256.0, -196.0, 8)
	_scatter_cobwebs(rng, 8.0, -256.0, -196.0, h, 5)
	# the wolf
	var wps: Array[Vector3] = [Vector3(-6, 0, -200), Vector3(6, 0, -204), Vector3(5, 0, -218), Vector3(-6, 0, -226), Vector3(-2, 0, -240), Vector3(6, 0, -250), Vector3(-6, 0, -254), Vector3(0, 0, -246), Vector3(6, 0, -234), Vector3(-5, 0, -212), Vector3(2, 0, -196)]
	outline_nodes[4] = []
	if not Engine.is_editor_hint():
		var w := CREATURE.new()
		w.name = "Wolf"
		level.add_child(w)
		w.setup("wolf", "wolf-base", 1.0, 2.0, 6.5, 1.6, 5.0, wps)
		w.place(Vector3(4, 0.1, -232))
		creatures["wolf"] = w
		if w._model != null and not (w._model is MeshInstance3D):
			outline_nodes[4] = AS.add_outline(w._model, 0.05)
			for n in outline_nodes[4]:
				n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				n.visible = (cave == 4)
		else:
			_missing["wolf-base"] = true
	_dress_cave4()


# ---------------------------------------------------------------- cave 5: the echo

func _build_lava(center: Vector3, size: Vector2) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, 0.1, size.y)
	bm.material = LB.material(Color(1.0, 0.3, 0.05), 3.0)
	mi.mesh = bm
	mi.position = center + Vector3(0, 0.04, 0)
	level.add_child(mi)
	LB.light(level, center + Vector3(0, 0.8, 0), Color(1.0, 0.35, 0.1), 2.0, 9.0)
	var area := Area3D.new()
	area.collision_mask = 0xFF
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(size.x, 1.6, size.y)
	cs.shape = bs
	area.add_child(cs)
	area.position = center + Vector3(0, 0.6, 0)
	level.add_child(area)
	area.body_entered.connect(_on_lava)


func _on_lava(body: Node3D) -> void:
	if running and body == local_player and not local_player.frozen:
		local_player.rpc_damage(1000.0)          # burns to death -> normal death logic


func _build_cave5(rng: RandomNumberGenerator) -> void:
	var h := 7.0
	hide_spots.clear()
	_ceil(-10.0, 10.0, -380.5, -259.5, h)
	_wall_side(-9.0, -1.0, -380.5, -259.5, h)
	_wall_side(9.0, 1.0, -380.5, -259.5, h)
	_wall_front(-380.0, -1.0, -10.0, 10.0, h)
	_floor(-10.0, 10.0, -320.0, -259.5)
	_floor(-10.0, 10.0, -380.5, -340.0)
	# the pit
	var pit := LB.material(Color(0.6, 0.1, 0.05), 1.2)
	LB.box(level, -9.0, 9.0, -13.0, -12.0, -340.0, -320.0, pit, false)
	LB.light(level, Vector3(0, -9.0, -330.0), Color(1, 0.3, 0.1), 2.0, 20.0)
	LB.box(level, -9.0, 9.0, -12.0, 0.0, -340.0, -339.8, floor_mat, false)
	LB.box(level, -9.0, 9.0, -12.0, 0.0, -320.2, -320.0, floor_mat, false)
	_avoid_box(0.0, -330.0, 10.0, 11.0)                     # nothing is placed over the pit / bridge
	# bridge planks (appear while wood is collected)
	for i in range(4):
		var z1 := -320.0 - i * 5.0
		var b := LB.box(level, -0.9, 0.9, -0.2, 0.0, z1 - 5.0, z1, bark_mat)
		b.visible = false
		b.collision_layer = 0
		planks.append(b)
	_avoid_box(0.0, -372.0, 4.0, 3.0)                       # the exit portal
	_decorate_rocks(rng, -9.0, 9.0, -318.0, -262.0, h, 18)
	# solid boulders (hiding places)
	for i in range(7):
		var bz := -270.0 - i * 6.5 if i < 5 else -346.0 - float(i - 5) * 12.0
		var bx := rng.randf_range(-6.5, 6.5)
		var byaw := rng.randf() * PI
		LB.rock_block(level, Vector3(bx, 0.7, bz), Vector3(1.8, 1.4, 1.5), byaw, rock)
		_solid(Vector3(bx, 0.7, bz), Vector3(1.8, 1.4, 1.5), 1, byaw)
		_avoid_box(bx, bz, 1.1, 1.1)
		_hide_behind(bx, bz, 1.1, rng.randf_range(-0.3, 0.3))
	# glowing crystals (visible to the blind player as outlines)
	var crystal_spots: Array[Vector3] = []
	for i in range(11):
		crystal_spots.append(Vector3(rng.randf_range(-7.5, 7.5), 0.0, -266.0 - i * 5.0))
	outline_nodes[5] = []
	for sp in crystal_spots:
		var g := Node3D.new()
		g.position = sp
		level.add_child(g)
		var cmat := LB.material(Color(0.3, 0.9, 1.0), 2.2)
		for j in range(3):
			var cm := CylinderMesh.new()
			cm.top_radius = 0.0
			cm.bottom_radius = rng.randf_range(0.12, 0.25)
			cm.height = rng.randf_range(0.7, 1.6)
			cm.radial_segments = 5
			cm.material = cmat
			var mi := MeshInstance3D.new()
			mi.mesh = cm
			mi.position = Vector3(rng.randf_range(-0.3, 0.3), cm.height / 2.0, rng.randf_range(-0.3, 0.3))
			mi.rotation = Vector3(rng.randf_range(-0.25, 0.25), 0.0, rng.randf_range(-0.25, 0.25))
			g.add_child(mi)
		LB.light(g, Vector3(0, 0.8, 0), Color(0.3, 0.9, 1.0), 0.9, 5.5)
		for n in AS.add_outline(g, 0.04):
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.visible = (cave == 5)
			outline_nodes[5].append(n)
	# wood for the bridge
	var wood_spots := [Vector3(-7, 0.2, -275), Vector3(7, 0.2, -287), Vector3(-6, 0.2, -300), Vector3(6, 0.2, -312)]
	for i in range(4):
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.16
		cyl.bottom_radius = 0.16
		cyl.height = 1.3
		cyl.material = bark_mat
		m.mesh = cyl
		m.position = wood_spots[i]
		m.rotation.z = PI / 2.0
		m.rotation.y = rng.randf() * PI
		level.add_child(m)
		LB.light(level, wood_spots[i] + Vector3(0, 1.0, 0), Color(1, 0.8, 0.5), 0.6, 3.0)
		_add_interact("wood_%d" % i, wood_spots[i], 2.0, "Press E - Pick up wood", 5, false, m)
	# gold chest (1 in this cave): near the exit, behind the boulders on the far side
	_place_chest(rng, 5,
		[Vector3(-7.4, 0, -360.0), Vector3(7.4, 0, -360.0), Vector3(-7.4, 0, -350.0), Vector3(7.4, 0, -352.0)],
		[PI / 2.0, -PI / 2.0, PI / 2.0, -PI / 2.0])
	_scatter_loot(rng, 5, -7.0, 7.0, -316.0, -266.0, 3, 2)
	_scatter_loot(rng, 5, -7.0, 7.0, -316.0, -266.0, 3, 2)
	_scatter_loot(rng, 5, -7.0, 7.0, -372.0, -346.0, 2, 1)
	_scatter_skulls(rng, -7.0, 7.0, -316.0, -266.0, 6)
	_scatter_skulls(rng, -7.0, 7.0, -372.0, -346.0, 4)
	_scatter_cobwebs(rng, 9.0, -316.0, -264.0, h, 5)
	_scatter_cobwebs(rng, 9.0, -376.0, -346.0, h, 3)
	# lava pool (the duck carries grabbed players here and throws them in)
	var lava_c := Vector3(-6.5, 0, -334.0)
	_build_lava(lava_c, Vector2(5.0, 6.0))
	# the duck monster
	var wps: Array[Vector3] = [Vector3(-7, 0, -270), Vector3(7, 0, -276), Vector3(6, 0, -292), Vector3(-1, 0, -306), Vector3(7, 0, -322), Vector3(0, 0, -340), Vector3(6, 0, -358), Vector3(-6, 0, -364), Vector3(1, 0, -350), Vector3(-1, 0, -322), Vector3(-7, 0, -296), Vector3(3, 0, -284)]
	if not Engine.is_editor_hint():
		var d := CREATURE.new()
		d.name = "Duck"
		level.add_child(d)
		d.setup("duck", "duck-base", 1.8, 1.8, 4.6, 1.0, 10.0, wps)
		d.place(Vector3(3, 0.1, -296))
		d.lava_pos = lava_c
		d.has_lava = true
		creatures["duck"] = d
		if d._model != null and not (d._model is MeshInstance3D):
			for n in AS.add_outline(d._model, 0.06):
				n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				n.visible = (cave == 5)
				outline_nodes[5].append(n)
		else:
			_missing["duck-base"] = true
	# the big green exit portal
	var ppos := Vector3(0, 0, -372.0)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 2.4
	tm.outer_radius = 3.1
	tm.material = LB.material(Color(0.2, 1, 0.3), 3.0)
	ring.mesh = tm
	ring.position = ppos + Vector3(0, 3.3, 0)
	ring.rotation_degrees.x = 90.0
	level.add_child(ring)
	var disc := MeshInstance3D.new()
	var dc := CylinderMesh.new()
	dc.top_radius = 2.5
	dc.bottom_radius = 2.5
	dc.height = 0.05
	var dmat := LB.material(Color(0.2, 1, 0.3, 0.5), 2.0)
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dc.material = dmat
	disc.mesh = dc
	disc.position = ppos + Vector3(0, 3.3, 0)
	disc.rotation_degrees.x = 90.0
	level.add_child(disc)
	LB.light(level, ppos + Vector3(0, 3.0, 2.0), Color(0.2, 1, 0.3), 3.0, 14.0)
	if not Engine.is_editor_hint():
		LB.area(level, -3.0, 3.0, 0.0, 6.6, ppos.z - 0.6, ppos.z + 0.6, _on_final_portal)
	_dress_cave5()
