extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var AS = load("res://assets.gd")
	for part in ["wolf-base", "duck-base"]:
		var m = AS.instance_fitted(part, 1.0)
		root.add_child(m)
		var ap = AS.find_anim_player(m)
		var anim = ap.get_animation("Idle")
		print("-- ", part, " tracks=", anim.get_track_count())
		for i in range(anim.get_track_count()):
			var p = anim.track_get_path(i)
			if "position" in str(p) or "scale" in str(p):
				print("  ", p, " keys=", anim.track_get_key_count(i))
				for k in range(mini(2, anim.track_get_key_count(i))):
					print("    ", k, " t=", anim.track_get_key_time(i, k), " v=", anim.track_get_key_value(i, k))
		m.queue_free()
		await process_frame
	quit()
