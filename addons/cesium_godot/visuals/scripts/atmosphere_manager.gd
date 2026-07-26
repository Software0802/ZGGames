
extends Node
class_name AtmosphereManager

@export var display_atmosphere: bool = false
@export var globe: CesiumGeoreference
@export var mesh_atmosphere: MeshInstance3D
@export var sun: DirectionalLight3D
@export var camera: GeoreferenceCameraController
var set_layers: bool = false


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	if display_atmosphere:
		update_settings()

		mesh_atmosphere.material_override = material
		##Value assigned to the atmosphere layer mask to try to make cull to the the physical range decals.
		if !set_layers:
			mesh_atmosphere.set_layer_mask_value(20, true)
			mesh_atmosphere.set_layer_mask_value(19, true)
			mesh_atmosphere.set_layer_mask_value(1, false)
			set_layers = true

		var cam_h = self.camera.last_hit_distance
		mesh_atmosphere.position = Vector3(0, 0, -cam_h)

	else:
		mesh_atmosphere.material_override = null
		set_layers = false

@export var base_material: ShaderMaterial = preload("res://addons/cesium_godot/visuals/mat_atmosphere.tres")
@export var atmosphere_settings: AtmosphereSettings = preload("res://addons/cesium_godot/visuals/scripts/atmosphere_settings.tres")

var material : ShaderMaterial
func _ready() -> void:
	material = base_material.duplicate()
	material.set_shader_parameter("AlphaValue", 0.27)

func update_settings():
	var source_viewport := get_viewport()
	const radius : float = 6378137.0
	atmosphere_settings.set_properties(material, radius)
	atmosphere_settings.atmosphere_scale = 0.1

	# Get the camera's position based on its ECEF coordinates
	var cam_ecef_pos := Vector3(self.globe.ecefX, self.globe.ecefY, self.globe.ecefZ)
	var cam_relative_engine_pos : Vector3 = self.globe.get_tx_ecef_to_engine() * cam_ecef_pos
	var centre : Vector3 = globe.global_position # We used to move this around
	material.set_shader_parameter("Cartographic", self.globe.origin_type == CesiumGeoreference.OriginType.CartographicOrigin)
	material.set_shader_parameter("DistanceToSurface", self.camera.last_hit_distance)
	material.set_shader_parameter("PlanetCentre", centre)
	material.set_shader_parameter("CameraWorldPos", cam_relative_engine_pos)
	material.set_shader_parameter("OceanRadius", radius)
	material.set_shader_parameter("ScreenWidth", source_viewport.size.x)
	material.set_shader_parameter("ScreenHeight", source_viewport.size.y)

	var dir_to_sun := Vector3.UP
	if sun:
		dir_to_sun = (sun.global_position - centre).normalized()

	material.set_shader_parameter("DirToSun", dir_to_sun)
