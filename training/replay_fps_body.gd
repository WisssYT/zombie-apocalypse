extends Node3D
## Stand-in for the player during playback: first_person_arms.gd reads these
## fields from its pivot's parent to pose the arms on the rifle.

var fps_mode := true
var dead := false
var reloading := false
var reload_time_left := 0.0
var reload_duration := 1.0
