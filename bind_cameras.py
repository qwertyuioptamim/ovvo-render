# =====================================================================
# bind_cameras.py — apply timeline-marker camera binding per frame.
#
# FREEZE. scenes ship with scene.camera = None; the shot's cameras are
# bound to timeline markers instead (e.g. clip 5: CAM_A_wide @f1,
# CAM_B_close @f91, CAM_C_wide @f171). Passed to Blender by
# render_chunk.sh BEFORE the -a render, this registers a
# frame_change_pre handler that sets scene.camera from the markers on
# every frame — so chunked range renders always use the right camera,
# even when a chunk starts mid-shot. If a scene has no camera markers,
# scene.camera is left untouched.
# =====================================================================
import bpy


def _bound_camera(scene, frame):
    """Camera bound by the latest marker at or before `frame`, or None."""
    chosen = None
    for m in sorted(scene.timeline_markers, key=lambda m: m.frame):
        if m.camera is None:
            continue
        if m.frame <= frame:
            chosen = m.camera
        else:
            break
    return chosen


def _on_frame_change(scene):
    cam = _bound_camera(scene, scene.frame_current)
    if cam is not None and scene.camera is not cam:
        scene.camera = cam


_scene = bpy.context.scene
_marks = [(m.frame, m.camera.name) for m in _scene.timeline_markers if m.camera]
if _marks:
    _cam = _bound_camera(_scene, _scene.frame_current)
    if _cam is not None:
        _scene.camera = _cam
    if _on_frame_change not in bpy.app.handlers.frame_change_pre:
        bpy.app.handlers.frame_change_pre.append(_on_frame_change)
    print("[bind_cameras] marker camera binding ACTIVE:", _marks)
else:
    print("[bind_cameras] no camera markers; scene.camera left as-is:",
          _scene.camera.name if _scene.camera else None)
