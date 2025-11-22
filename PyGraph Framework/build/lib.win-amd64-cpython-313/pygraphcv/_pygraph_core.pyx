# _pygraph_core.pyx
import numpy as np
cimport numpy as np
import cv2
from libc.math cimport sin, cos, tan, M_PI, sqrt, fabs, floor
from typing import Dict, Tuple, Optional as Opt
# NEW IMPORTS FOR FONT HANDLING
from PIL import ImageFont, ImageDraw, Image

# --- Type Definitions for Cython ---
ctypedef double float64_t
ctypedef np.float64_t DTYPE_FLOAT
ctypedef np.uint8_t DTYPE_UINT8

# Define C function for radians conversion (PI/180)
cdef inline double c_radians(double angle_deg) noexcept:
    return angle_deg * M_PI / 180.0

# ROTATION: 2D Point (Optimized: C-tuple return)
cdef (double, double) rotate_point_deg(double x, double y, double angle_deg) noexcept:
    cdef double a = c_radians(angle_deg)
    cdef double c = cos(a)
    cdef double s = sin(a)
    return x * c - y * s, x * s + y * c

# ADD_TUPLES (Optimized: Explicit length checks for speed)
cpdef tuple add_tuples(tuple t1, tuple t2):
    cdef Py_ssize_t len1 = len(t1), len2 = len(t2)
    # Check for 3D case
    if len1 == 3 and len2 == 3:
        return t1[0] + t2[0], t1[1] + t2[1], t1[2] + t2[2]
    # Check for 2D case
    if len1 == 2 and len2 == 2:
        return t1[0] + t2[0], t1[1] + t2[1]
    # Fallback (Should typically be 2D if lengths mismatch)
    return t1[0] + t2[0], t1[1] + t2[1]

# ROTATION: 3D Point
cdef (double, double, double) rotate_point_3d(double x, double y, double z, double pitch, double yaw, double roll) noexcept:
    cdef double p, a, r
    cdef double cr, sr, ca, sa, cp, sp
    cdef double x1, y1, z1_temp, x2, y2
    
    p = c_radians(pitch); a = c_radians(yaw); r = c_radians(roll)
    cr, sr = cos(r), sin(r); ca, sa = cos(a), sin(a); cp, sp = cos(p), sin(p)

    # Yaw (around Y-axis)
    x1 = x * ca + z * sa
    z1_temp = z * ca - x * sa
    y1 = y
    
    # Pitch (around X-axis, using new Z)
    y2 = y1 * cp - z1_temp * sp
    z1_temp = y1 * sp + z1_temp * cp
    
    # Roll (around Z-axis, using final Z)
    x2 = x1
    return x2 * cr - y2 * sr, x2 * sr + y2 * cr, z1_temp

# PERSPECTIVE: Projection
cdef (double, double, double) perspective_projection(double x, double y, double z, double fov) noexcept:
    cdef double f = 1.0 / tan(c_radians(fov) / 2.0)
    if fabs(z) > 1e-6:
        return (x / z) * f, (y / z) * f, z
    # Return a negative depth to indicate 'behind camera'
    return 0.0, 0.0, -1.0 

# IMAGE DRAWING: apply_homography
cpdef (double, double) apply_homography(H, pt):
    # Enforce C-contiguous memory layout
    cdef np.ndarray[float64_t, ndim=2, mode="c"] H_arr = np.asarray(H, dtype=np.float64)
    cdef np.ndarray vec = np.array([pt[0], pt[1], 1.0], dtype=np.float64)
    cdef np.ndarray res
    
    res = H_arr @ vec
    
    cdef double w = res[2]
    # Check for homography division by zero/near-zero
    return (res[0] / w, res[1] / w) if fabs(w) > 1e-6 else pt

# TRANSFORM: 3D
cpdef (double, double, double) transform_3d(tuple p, dict ts):
    cdef double px, py, pz, cx, cy, cz, x_cam, y_cam, z_cam
    cdef double rot_angle, scale
    cdef double x_rot, y_rot, z_rot, x_proj, y_proj, depth

    rot_angle = <double>ts['rot']
    scale = <double>ts['size']
    
    px = <double>p[0]; py = <double>p[1]
    pz = <double>p[2] if len(p) == 3 else 0.0

    # World space rotation and scaling
    px, py = rotate_point_deg(px, py, rot_angle)
    px *= scale; py *= scale; pz *= scale
    
    # Camera position and translation
    cx = <double>ts['cam_pos_3d'][0]
    cy = <double>ts['cam_pos_3d'][1]
    cz = <double>ts['cam_pos_3d'][2]
    x_cam, y_cam, z_cam = px - cx, py - cy, pz - cz
    
    # Camera rotation
    x_rot, y_rot, z_rot = rotate_point_3d(
        x_cam, y_cam, z_cam, 
        <double>ts['cam_rot_3d'][0], <double>ts['cam_rot_3d'][1], <double>ts['cam_rot_3d'][2]
    )
    
    # Perspective projection and Screen shift
    x_proj, y_proj, depth = perspective_projection(x_rot, y_rot, z_rot, 90.0) 
    
    return x_proj + <double>ts['shift'][0], y_proj + <double>ts['shift'][1], depth

# TRANSFORM: 2D/3D Unified (Optimized: Explicit type casts)
cpdef (double, double) transform(tuple p, dict ts):
    cdef double px, py 
    cdef double x_scr, y_scr, depth 
    cdef bint is_3d = <bint>ts['is_3d']

    if is_3d:
        x_scr, y_scr, depth = transform_3d(p if len(p) == 3 else (p[0], p[1], 0.0), ts)
        return (x_scr, y_scr) if depth >= 1e-6 else (np.inf, np.inf)

    # 2D path
    px = <double>p[0]; py = <double>p[1]
    px, py = rotate_point_deg(px, py, <double>ts['rot'])
    
    px = px * <double>ts['size'] + <double>ts['shift'][0]
    py = py * <double>ts['size'] + <double>ts['shift'][1]

    if ts.get('full_transform') is not None:
        return apply_homography(ts['full_transform'], (px, py))
        
    return px, py

# TRANSFORM: Inverse (World from Screen) (Optimized: Explicit type casts)
cpdef (double, double, double) inverse_transform(tuple s, dict ts): 
    cdef double sx, sy, px, py, wx, wy, rot_angle, scale
    
    sx = <double>s[0]; sy = <double>s[1]
    rot_angle = -<double>ts['rot']; scale = <double>ts['size']

    if ts.get('full_transform_inv') is not None:
        sx, sy = apply_homography(ts['full_transform_inv'], (sx, sy))
        
    px = sx - <double>ts['shift'][0]
    py = sy - <double>ts['shift'][1]

    if fabs(scale) < 1e-6:
        return (0.0, 0.0, 0.0) 
        
    px /= scale; py /= scale
    
    wx, wy = rotate_point_deg(px, py, rot_angle)
    
    return (wx, wy, 0.0)

# DRAWING HELPERS: cv2 line type
cdef inline int _lt(bint aa) noexcept:
    return cv2.LINE_AA if aa else cv2.LINE_4 

# DRAWING HELPERS: BGR Color Conversion
cpdef tuple _color_bgr(tuple color):
    # Converts an RGB color tuple (R, G, B) to BGR (B, G, R) for cv2 compatibility.
    return (color[2], color[1], color[0])

# DRAWING HELPERS: Transform Points (Optimization uses Cdef transform functions)
cdef list _trans_pts(list pts, dict ts):
    """Transforms a list of world points to screen points."""
    cdef list spts = []
    cdef bint is_3d = <bint>ts['is_3d']
    cdef tuple p
    cdef double x_scr, y_scr, depth
    
    for p in pts:
        if is_3d:
            x_scr, y_scr, depth = transform_3d(p, ts)
            spts.append((x_scr, y_scr) if depth >= 1e-6 else None)
        else:
            x_scr, y_scr = transform(p, ts)
            if not np.isinf(x_scr):
                spts.append((x_scr, y_scr))
            else:
                spts.append(None)
    return spts

# DRAWING PRIMITIVES
cpdef clear(np.ndarray arr, dict ts, tuple color):
    cdef int W = arr.shape[1]
    cdef int H = arr.shape[0]
    cv2.rectangle(arr, (0, 0), (W, H), _color_bgr(color), -1)

cpdef void line(np.ndarray arr, dict ts, tuple d, tuple color, int thickness, bint aa=False):
    cdef double t_size = <double>ts['size']
    cdef int t = max(1, int(thickness * t_size))
    cdef tuple start, end, start_scr, end_scr, d_match
    
    # Ensure d_match has the correct dimension for add_tuples
    d_match = d + (0.0,) * (len(ts['cursor_pos']) - len(d))
    start = ts['cursor_pos']
    end = add_tuples(start, d_match)
    
    ts['cursor_pos'] = end
    start_scr, end_scr = _trans_pts([start, end], ts)
    
    if start_scr and end_scr:
        cv2.line(
            arr, 
            (int(start_scr[0]), int(start_scr[1])), 
            (int(end_scr[0]), int(end_scr[1])), 
            _color_bgr(color), t, lineType=_lt(aa)
        )

# RECT (Optimized 2D path)
cpdef void rect(np.ndarray arr, dict ts, tuple wh, tuple color, int thickness, bint fill=False, bint aa=False):
    cdef double t_size = <double>ts['size']
    cdef int t = max(1, int(thickness * t_size))
    cdef double w = <double>wh[0], h = <double>wh[1], z
    cdef tuple p1 = ts['cursor_pos']
    cdef tuple start_scr, end_scr
    cdef list pts_world
    cdef list screen_points
    cdef np.ndarray pts
    cdef int lt 

    if ts['is_3d']:
        z = <double>p1[2] if len(p1) == 3 else 0.0 
        pts_world = [p1, (p1[0] + w, p1[1], z), (p1[0] + w, p1[1] + h, z), (p1[0], p1[1] + h, z)]
        screen_points = _trans_pts(pts_world, ts)
        
        if all(screen_points):
            pts = np.array(screen_points, np.int32).reshape((-1, 1, 2))
            lt = _lt(aa) if not fill else cv2.LINE_4 
            if fill: cv2.fillPoly(arr, [pts], _color_bgr(color))
            else: cv2.polylines(arr, [pts], True, _color_bgr(color), t, lineType=lt)
    else:
        # Optimized 2D path: Only transform two corners
        start_scr = transform(p1, ts)
        end_scr = transform((p1[0] + w, p1[1] + h), ts)
        
        if not np.isinf(start_scr[0]) and not np.isinf(end_scr[0]):
            cv2.rectangle(
                arr, 
                (int(start_scr[0]), int(start_scr[1])), 
                (int(end_scr[0]), int(end_scr[1])), 
                _color_bgr(color), 
                -1 if fill else t, 
                lineType=_lt(aa)
            )

# POLY (Optimization ensures minimal Python interaction in the loop)
cpdef void poly(np.ndarray arr, dict ts, tuple ds, tuple color, int thickness, bint fill=False, bint aa=False):
    cdef int t = max(1, int(thickness * <double>ts['size']))
    cdef list pts = [ts['cursor_pos']]
    cdef tuple d
    cdef list screen_points
    cdef np.ndarray poly_pts 
    
    # 1. Build list of world points
    for d in ds:
        pts.append(add_tuples(pts[-1], d + (0.0,) * (len(pts[-1]) - len(d))))
        
    # 2. Transform all world points to screen points
    screen_points = _trans_pts(pts, ts)
    
    # 3. Draw using OpenCV
    if all(screen_points):
        poly_pts = np.array(screen_points, np.int32).reshape((-1, 1, 2))
        
        if fill:
            cv2.fillPoly(arr, [poly_pts], _color_bgr(color))
        else:
            cv2.polylines(arr, [poly_pts], True, _color_bgr(color), t, lineType=_lt(aa))

# CIRCLE (Optimized: C-level calculation of points/deltas)
cpdef void circle(np.ndarray arr, dict ts, double radius, tuple color, int thickness=1, bint fill=False, bint aa=False, double multiplier=1.0):
    cdef double r_check, factor, angle, x, y, prev_x, prev_y, angle_step
    cdef int num_points, i
    cdef list deltas = []
    cdef double PI = M_PI
    cdef double t_size = <double>ts['size']
    cdef tuple start_point, temp_cursor_pos
    
    # 1. Heuristic for point count
    for r_check, factor in [(200.0, 1.5), (150.0, 1.5), (100.0, 2.0), (50.0, 2.0)]:
        if radius >= r_check: multiplier /= factor
    
    num_points = max(6, int(radius * multiplier))
    angle_step = 2.0 * PI / num_points
    
    # 2. Pre-calculate deltas and start point
    prev_x, prev_y = radius, 0.0
    start_point = (<double>ts['cursor_pos'][0] + prev_x, <double>ts['cursor_pos'][1] + prev_y)

    for i in range(1, num_points + 1):
        angle = i * angle_step
        x = radius * cos(angle); y = radius * sin(angle)
        
        # Calculate delta (relative to previous point)
        deltas.append((x - prev_x, y - prev_y))
        prev_x, prev_y = x, y
        
    # 3. Use poly to draw the line/fill
    temp_cursor_pos = ts['cursor_pos'] 
    ts['cursor_pos'] = start_point
    
    # Pass a tuple of deltas for faster argument handling
    poly(arr, ts, tuple(deltas), color=color, thickness=thickness, fill=fill, aa=aa)
    
    # Restore cursor position
    ts['cursor_pos'] = temp_cursor_pos

cpdef void ellipse(np.ndarray arr, dict ts, double rx, double ry, tuple color, int thickness=1, bint fill=False, bint aa=False, double multiplier=1.0):
    """
    Draws an ellipse centered at cursor_pos with radii rx and ry.
    Approximate smooth drawing using OpenCV ellipse function in 2D or polyline in 3D.
    """
    cdef double t_size = <double>ts['size']
    cdef int t = max(1, int(thickness * t_size))
    cdef tuple center_scr
    cdef tuple temp_cursor_pos = ts['cursor_pos']

    # 2D Optimized Path: Use cv2.ellipse (fast, handles rotation and center)
    if not ts['is_3d']:
        center_scr = transform(temp_cursor_pos, ts)

        if not np.isinf(center_scr[0]):
            scr_rx = int(rx * t_size)
            scr_ry = int(ry * t_size)
            rot_deg = <double>ts['rot']

            cv2.ellipse(
                arr,
                (int(center_scr[0]), int(center_scr[1])),
                (scr_rx, scr_ry),
                rot_deg,               # Angle: Uses current world rotation
                0.0, 360.0,            # Start/End Angle
                _color_bgr(color),
                -1 if fill else t,
                lineType=_lt(aa)
            )
    else:
        # 3D Path: Use point approximation to respect perspective distortion
        x, y, angle_step, angle = (
         0, 0, 0, 0
        )
        num_points, i = (0, 0)
        PI = M_PI
        r_check, factor = (0, 0)
        max_r = max(rx, ry)

        # Heuristic for point count based on largest radius for smoothness
        for r_check, factor in [(200.0, 1.5), (150.0, 1.5), (100.0, 2.0), (50.0, 2.0)]:
            if max_r >= r_check: multiplier /= factor

        num_points = max(12, int(max_r * multiplier * 2.0))
        angle_step = 2.0 * PI / num_points

        # Calculate world points relative to (0, 0) offset by cursor_pos
        world_pts = []
        c_x = <double>temp_cursor_pos[0]
        c_y = <double>temp_cursor_pos[1]
        c_z = <double>temp_cursor_pos[2] if len(temp_cursor_pos) == 3 else 0.0

        for i in range(num_points + 1):
            angle = i * angle_step
            x = c_x + rx * cos(angle)
            y = c_y + ry * sin(angle)
            world_pts.append((x, y, c_z))

        # Transform and draw using polylines
        screen_points = _trans_pts(world_pts, ts)
        valid_points = [p for p in screen_points if p is not None]

        if len(valid_points) >= 2:
            poly_pts = np.array(valid_points, np.int32).reshape((-1, 1, 2))

            if fill:
                cv2.fillPoly(arr, [poly_pts], _color_bgr(color))
            else:
                # The ellipse is a closed shape, so set isClosed=True
                cv2.polylines(arr, [poly_pts], True, _color_bgr(color), t, lineType=_lt(aa))


cpdef void arc(np.ndarray arr, dict ts, double radius, double start_deg, double end_deg, tuple color, int thickness=1, bint aa=False, double multiplier=1.0):
    """
    Draws an arc (a segment of a circle) centered at cursor_pos.
    Uses point approximation for smoothness in both 2D and 3D.
    """
    cdef double t_size = <double>ts['size']
    cdef int t = max(1, int(thickness * t_size))
    cdef double start_rad = c_radians(start_deg)
    cdef double end_rad = c_radians(end_deg)
    cdef double angle_range = end_rad - start_rad
    cdef double angle_step
    cdef int num_points, i
    cdef double PI = M_PI
    cdef list world_pts = []
    cdef tuple temp_cursor_pos = ts['cursor_pos']
    cdef double c_x = <double>temp_cursor_pos[0]
    cdef double c_y = <double>temp_cursor_pos[1]
    cdef double c_z = <double>temp_cursor_pos[2] if len(temp_cursor_pos) == 3 else 0.0
    cdef double angle

    # Normalize angle_range to be positive [0, 2*PI]
    while angle_range < 0.0: angle_range += 2.0 * PI
    while angle_range > 2.0 * PI: angle_range -= 2.0 * PI
    if angle_range < 1e-6: return

    # Heuristic for point count based on arc length for smoothness
    num_points = max(2, int(radius * multiplier * angle_range / (2.0 * PI) * 6.0))
    angle_step = angle_range / num_points

    # Generate points in world space
    for i in range(num_points + 1):
        angle = start_rad + i * angle_step
        x = c_x + radius * cos(angle)
        y = c_y + radius * sin(angle)
        world_pts.append((x, y, c_z))

    # Transform and draw
    cdef list screen_points = _trans_pts(world_pts, ts)

    # Convert non-None screen points to a NumPy array for polylines
    cdef list valid_points = [p for p in screen_points if p is not None]
    if len(valid_points) >= 2:
        poly_pts = np.array(valid_points, np.int32).reshape((-1, 1, 2))
        # Draw the arc as an open polyline (isClosed=False)
        cv2.polylines(arr, [poly_pts], False, _color_bgr(color), t, lineType=_lt(aa))


cpdef void graph(np.ndarray arr, dict ts, object func, double x_min, double x_max, tuple color, int thickness=1, bint aa=True, int resolution=100, double y_scale=1, double x_scale=1, int max_depth=5, double angle_threshold=0.1, double screen_dist_threshold=5.0, bint x_world=False):
    """
    Plots a 1D function y = f(x) from x_min to x_max using adaptive resolution.
    - resolution: Serves as the *initial* number of segments.
    - max_depth: Limits how many times a segment can be subdivided.
    - angle_threshold: Maximum allowed change in angle (radians) between segments before subdivision.
    - screen_dist_threshold: Maximum allowed distance (pixels) between screen points before subdivision.
    """
    if x_min >= x_max: return

    cdef double t_size = <double>ts['size']
    cdef int t = max(1, int(thickness * t_size))
    
    cdef list world_pts = []
    
    # Store points as tuples of (world_x, world_y, world_z)
    cdef list initial_world_pts = []
    
    # Cursor offsets for world transformation
    cdef tuple temp_cursor_pos = ts['cursor_pos']
    cdef double c_y_origin = <double>temp_cursor_pos[1]
    cdef double c_z = <double>temp_cursor_pos[2] if len(temp_cursor_pos) == 3 else 0.0
    cdef double c_x_offset = <double>temp_cursor_pos[0]

    # --- Initial Point Generation ---
    cdef double initial_step_size = (x_max - x_min) / resolution
    cdef double x, y
    cdef int i
    
    for i in range(resolution + 1):
        # Compute either world-space sampling or function-domain sampling
        if x_world:
            # x_min/x_max are in world coordinates already
            x_world_val = x_min + i * initial_step_size
            # convert to function domain
            x_func = (x_world_val - c_x_offset) / x_scale if x_scale != 0 else x_world_val - c_x_offset
        else:
            # x_min/x_max are in function domain
            x_func = x_min + i * initial_step_size

        try:
            y = func(x_func)
        except Exception:
            continue

        # Scale and offset values
        y = c_y_origin + y * y_scale
        if x_world:
            x_world_final = x_min + i * initial_step_size
        else:
            x_world_final = c_x_offset + x_func * x_scale
        initial_world_pts.append((x_world_final, y, c_z))

    # If too few points, return early
    if len(initial_world_pts) < 2: return

    # --- Adaptive Subdivision Loop ---
    # We will use the initial points as a starting point for subdivision.
    world_pts = [initial_world_pts[0]]
    cdef list world_stack = []

    # Push all initial segments onto the stack. A segment is (P1, P2, depth)
    for i in range(len(initial_world_pts) - 1):
        # We start with depth 0
        world_stack.append((initial_world_pts[i], initial_world_pts[i+1], 0))

    cdef tuple p1_w, p2_w, p_mid_w
    cdef int depth
    cdef double x1, y1, x2, y2, x_mid, y_mid
    cdef tuple p1_s, p2_s, p_mid_s # Screen coordinates

    # Pre-transform p1_w to screen space for the threshold check
    p1_s = _trans_pts([initial_world_pts[0]], ts)[0]
    if p1_s is None:
        return # Cannot transform the first point, abort.

    while world_stack:
        p1_w, p2_w, depth = world_stack.pop()
        
        # Transform the second point to screen space for the threshold check
        p2_s = _trans_pts([p2_w], ts)[0]

        # Get world coordinates for midpoint calculation
        x1, y1 = p1_w[0], p1_w[1]
        x2, y2 = p2_w[0], p2_w[1]
        # Check if subdivision is needed (or possible)
        subdivide = False
        # 1. Check max depth limit
        if depth >= max_depth:
            subdivide = False
        # 2. Check for steepness / change in line (in screen space)
        elif p1_s is not None and p2_s is not None:
            # Simple check: distance in screen space is too large (more detail needed)
            screen_dist_sq = (p2_s[0] - p1_s[0])**2 + (p2_s[1] - p1_s[1])**2
            if screen_dist_sq > screen_dist_threshold * screen_dist_threshold:
                subdivide = True
        elif p1_s is None or p2_s is None:
            # If one point is off-screen, it's safer to subdivide up to max_depth
            subdivide = False
        if subdivide:
            # Calculate midpoint x in the original function domain (inverse of world transform)
            # x = c_x_offset + x_func * x_scale  =>  x_func = (x - c_x_offset) / x_scale
            x_mid_func = (((x1 + x2) / 2.0) - c_x_offset) / x_scale
            # Evaluate function at midpoint
            try:
                y_mid_func = func(x_mid_func)
            except Exception:
                # If function fails, treat as a break, don't subdivide
                world_pts.append(p2_w)
                p1_s = p2_s # Prepare for the next segment
                continue
            # Transform midpoint back to world coordinates
            y_mid = c_y_origin + y_mid_func * y_scale
            x_mid = c_x_offset + x_mid_func * x_scale # Recalculate full world x_mid
            p_mid_w = (x_mid, y_mid, c_z)
            
            # Subdivide: Push two new segments onto the stack
            world_stack.append((p_mid_w, p2_w, depth + 1))
            world_stack.append((p1_w, p_mid_w, depth + 1))
            # Note: The order ensures we process the left half first in the *next* iteration
        else:
            # No subdivision needed, add the second point and continue to the next segment
            world_pts.append(p2_w)
            p1_s = p2_s # Prepare for the next segment
    # --- Transformation and Drawing (robust) ---
    cdef list screen_points = _trans_pts(world_pts, ts)

    # Split into continuous segments: remove None, non-finite, and absurdly-large coordinates
    # but do not connect across gaps — draw each continuous run separately.
    cdef int W = arr.shape[1]
    cdef int H = arr.shape[0]
    cdef double px, py
    cdef double margin = 1200.0  # allow some leeway beyond screen for continuity

    cdef list seg = []
    for p in screen_points:
        if p is None:
            # end current segment
            if len(seg) >= 2:
                poly_pts = np.array(seg, np.int32).reshape((-1, 1, 2))
                cv2.polylines(arr, [poly_pts], False, _color_bgr(color), t, lineType=_lt(aa))
            seg = []
            continue

        px, py = p[0], p[1]
        # skip non-finite values
        if not (np.isfinite(px) and np.isfinite(py)):
            if len(seg) >= 2:
                poly_pts = np.array(seg, np.int32).reshape((-1, 1, 2))
                cv2.polylines(arr, [poly_pts], False, _color_bgr(color), t, lineType=_lt(aa))
            seg = []
            continue

        # skip absurdly large coords which cause long off-screen lines
        if px < -margin or px > W + margin or py < -margin or py > H + margin:
            if len(seg) >= 2:
                poly_pts = np.array(seg, np.int32).reshape((-1, 1, 2))
                cv2.polylines(arr, [poly_pts], False, _color_bgr(color), t, lineType=_lt(aa))
            seg = []
            continue

        # append valid point to current segment
        seg.append((int(px), int(py)))

    # draw final segment if any
    if len(seg) >= 2:
        poly_pts = np.array(seg, np.int32).reshape((-1, 1, 2))
        cv2.polylines(arr, [poly_pts], False, _color_bgr(color), t, lineType=_lt(aa))
# BLIT CORE (Optimized: C-level transformation and Homography calculation)
cdef np.ndarray blit_core(np.ndarray arr, dict ts, np.ndarray src_img, tuple dest_world) noexcept:
    cdef list screen_points
    cdef np.ndarray dst_corners
    cdef np.ndarray src_corners
    cdef np.ndarray M
    cdef int W = src_img.shape[1]
    cdef int H = src_img.shape[0]

    # 1. Transform world-space corners to screen pixels
    # _trans_pts is a cdef function and is used here.
    screen_points = _trans_pts(list(dest_world), ts)
    
    # Check if all points were successfully projected
    if not all(screen_points):
        return None # Return None to signal failure/clipping

    # 2. Prepare corner arrays for Homography
    src_corners = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    dst_corners = np.float32(screen_points)

    # 3. Calculate the transformation matrix
    M = cv2.getPerspectiveTransform(src_corners, dst_corners)
    
    # 4. Apply the warp (This part remains OpenCV/C++)
    return cv2.warpPerspective(src_img, M, (arr.shape[1], arr.shape[0]), flags=cv2.INTER_LINEAR)


# -------------------- PYTHON/LIBRARY WRAPPERS --------------------

import sys, os, time, threading, math, shutil, glob
import numpy as np; import cv2
import pygame; pygame.mixer.init(44100, -16, 2, 512)
from pynput import keyboard, mouse

# NEW FONT CACHE
FONT_CACHE: Dict[Tuple[str, int], ImageFont.FreeTypeFont] = {}


# Globals
GLOBAL_VOLUME = [1.0]; KEYS = {}; RUN = True
MOUSE_SCR_POS = (0, 0)
MOUSE_STATE = {'world_pos':(0.0, 0.0), 'buttons':[False] * 3, 'scroll':0.0}
TS_STACK = []
TEXT_FILE_EXTENSIONS = ['.tvf', '.txt', '.json', '.csv', '.md', '.py', '.c', '.pyx', '.tsx']

# Asset Management
class AssetManager:
    """Manages cached assets."""
    def __init__(self):self.images:Dict[str, np.ndarray] = {}; self.sounds:Dict[str, pygame.mixer.Sound] = {}
    def load_image(self, name:str, path:str):
        if name in self.images:return
        try:
            img = cv2.imread(path, cv2.IMREAD_UNCHANGED); self.images[name] = img
        except Exception as e:print(f"Asset Error loading image '{name}':{e}")
    def load_sound(self, name:str, path:str):
        if name in self.sounds:return
        try:self.sounds[name] = pygame.mixer.Sound(path)
        except Exception as e:print(f"Asset Error loading sound '{name}':{e}")
    def get_img(self, name:str) ->Opt[np.ndarray]:return self.images.get(name)
    def get_snd(self, name:str) ->Opt[pygame.mixer.Sound]:return self.sounds.get(name)
ASSETS = AssetManager()

# Color definitions (rgb)
C = {
'W':(255, ) * 3, 'DW':(200, ) * 3, 'DDW':(140, ) * 3, 'LW':(255, ) * 3, 'LLW':(255, ) * 3, 
'K':(0, ) * 3, 'DK':(25, ) * 3, 'DDK':(10, ) * 3, 'LK':(50, ) * 3, 'LLK':(90, ) * 3, 
'G':(128, ) * 3, 'DG':(90, ) * 3, 'DDG':(50, ) * 3, 'LG':(170, ) * 3, 'LLG':(210, ) * 3, 
'R':(255, 0, 0), 'DR':(180, 0, 0), 'DDR':(100, 0, 0), 'LR':(255, 80, 80), 'LLR':(255, 140, 140), 
'M':(255, 0, 255), 'DM':(190, 0, 190), 'DDM':(110, 0, 110), 'LM':(255, 90, 255), 'LLM':(255, 170, 255), 
'PU':(128, 0, 118), 'DPU':(90, 0, 80), 'DDPU':(50, 0, 40), 'LPU':(170, 50, 160), 'LLPU':(210, 110, 200), 
'V':(148, 0, 211), 'DV':(100, 0, 150), 'DDV':(60, 0, 100), 'LV':(180, 60, 230), 'LLV':(210, 110, 250), 
'O':(255, 165, 0), 'DO':(200, 120, 0), 'DDO':(140, 80, 0), 'LO':(255, 190, 70), 'LLO':(255, 220, 130), 
'BR':(139, 69, 19), 'DBR':(100, 50, 10), 'DDBR':(60, 30, 5), 'LBR':(170, 100, 40), 'LLBR':(200, 140, 80), 
'GO':(232, 200, 0), 'DGO':(180, 150, 0), 'DDGO':(120, 100, 0), 'LGO':(255, 220, 70), 'LLGO':(255, 240, 130), 
'Y':(255, 255, 0), 'DY':(200, 200, 0), 'DDY':(140, 140, 0), 'LY':(255, 255, 100), 'LLY':(255, 255, 170), 
'OL':(128, 128, 0), 'DOL':(90, 90, 0), 'DDOL':(60, 60, 0), 'LOL':(170, 170, 50), 'LLOL':(210, 210, 100), 
'GR':(0, 255, 0), 'DGR':(0, 180, 0), 'DDGR':(0, 100, 0), 'LGR':(80, 255, 80), 'LLGR':(150, 255, 150), 
'C':(0, 255, 255), 'DC':(0, 180, 180), 'DDC':(0, 100, 100), 'LC':(80, 255, 255), 'LLC':(150, 255, 255), 
'T':(0, 128, 128), 'DT':(0, 90, 90), 'DDT':(0, 60, 60), 'LT':(50, 170, 170), 'LLT':(110, 210, 210), 
'BL':(0, 0, 255), 'DBL':(0, 0, 180), 'DDBL':(0, 0, 100), 'LBL':(70, 70, 255), 'LLBL':(140, 140, 255), 
'N':(16, 0, 128), 'DN':(12, 0, 90), 'DDN':(8, 0, 50), 'LN':(60, 40, 170), 'LLN':(110, 90, 220), 
'P':(255, 182, 193), 'DP':(200, 130, 150), 'DDP':(140, 80, 100), 'LP':(255, 200, 210), 'LLP':(255, 225, 235), 
'S':(192, 192, 192), 'DS':(150, 150, 150), 'DDS':(100, 100, 100), 'LS':(220, 220, 220), 'LLS':(240, 240, 240), 
'CO':(184, 115, 51), 'DCO':(140, 90, 40), 'DDCO':(90, 60, 20), 'LCO':(210, 150, 80), 'LLCO':(240, 190, 130), 
'SI':(192, 192, 192), 'DSI':(150, 150, 150), 'DDSI':(100, 100, 100), 'LSI':(220, 220, 220), 'LLSI':(240, 240, 240), 
'TU':(64, 224, 208), 'DTU':(50, 170, 160), 'DDTU':(30, 110, 100), 'LTU':(110, 250, 230), 'LLTU':(160, 255, 245), 
'LG':(50, 205, 50), 'DLG':(40, 150, 40), 'DDLG':(25, 100, 25), 'LLG':(150, 255, 150), 'LLLG':(200, 255, 200), 
'AQ':(127, 255, 212), 'DAQ':(90, 200, 160), 'DDAQ':(60, 130, 100), 'LAQ':(160, 255, 230), 'LLAQ':(200, 255, 245), 
'CR':(220, 20, 60), 'DCR':(160, 10, 40), 'DDCR':(100, 5, 25), 'LCR':(250, 100, 120), 'LLCR':(255, 160, 180), 
'SA':(250, 128, 114), 'DSA':(200, 90, 80), 'DDSA':(140, 60, 50), 'LSA':(255, 170, 150), 'LLSA':(255, 210, 190), 
'LM':(255, 160, 122), 'DLM':(200, 120, 90), 'DDLM':(130, 70, 50), 'LLM':(255, 190, 160), 'LLLM':(255, 220, 190), 
'PE':(255, 218, 185), 'DPE':(210, 180, 150), 'DDPE':(150, 120, 90), 'LPE':(255, 230, 200), 'LLPE':(255, 245, 225), 
'SAF':(46, 139, 87), 'DSAF':(35, 100, 65), 'DDSAF':(20, 60, 40), 'LSAF':(80, 180, 120), 'LLSAF':(120, 220, 160), 
'SK':(135, 206, 235), 'DSK':(90, 150, 180), 'DDSK':(60, 100, 120), 'LSK':(170, 230, 250), 'LLSK':(200, 240, 255), 
'SB':(70, 130, 180), 'DSB':(50, 100, 140), 'DDSB':(30, 70, 90), 'LSB':(120, 180, 230), 'LLSB':(160, 210, 250), 
'IN':(75, 0, 130), 'DIN':(55, 0, 90), 'DDIN':(35, 0, 55), 'LIN':(110, 40, 160), 'LLIN':(150, 90, 200), 
'PL':(221, 160, 221), 'DPL':(180, 120, 180), 'DDPL':(130, 80, 130), 'LPL':(240, 180, 240), 'LLPL':(255, 210, 255), 
}

# --- Transform State (TS) Management ---
STATE_KEYS = ['shift', 'rot', 'size', 'cursor_pos', 'full_transform', 'full_transform_inv', 'cam_pos_3d', 'cam_rot_3d', 'is_3d']
push_state = lambda ts:TS_STACK.append({k:ts[k] for k in STATE_KEYS})
pop_state = lambda ts:ts.update(TS_STACK.pop()) if TS_STACK else None
peek_state = lambda ts:ts.update(TS_STACK[-1].copy()) if TS_STACK else None
set_cam_pos = lambda ts, p:ts.update({'cam_pos_3d':tuple(map(float, p))})
set_cam_rot = lambda ts, r:ts.update({'cam_rot_3d':tuple(map(float, r))})
cycle_state = lambda ts:TS_STACK.insert(0, TS_STACK.pop()) if TS_STACK else None
def set_3d_mode(ts:Dict, is_3d:bool):
    ts['is_3d'] = is_3d
    cp = ts['cursor_pos']
    if is_3d and len(cp) == 2:ts['cursor_pos'] = (cp[0], cp[1], 0.0)
    elif not is_3d and len(cp) == 3:ts['cursor_pos'] = (cp[0], cp[1])

# --- Drawing Primitives Helpers ---
cpdef tuple set_homography_core(list src_pts, list dst_pts):
    """
    Calculates the 3x3 Homography matrix (full_transform) and its inverse from 4 source points to 4 destination points.
    Used internally by set_homography.
    """
    cdef np.ndarray[float64_t, ndim=2] src = np.asarray(src_pts, dtype=np.float64)
    cdef np.ndarray[float64_t, ndim=2] dst = np.asarray(dst_pts, dtype=np.float64)
    H, _ = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
    H_inv, _ = cv2.findHomography(dst, src, cv2.RANSAC, 5.0)
    if H is None or H_inv is None:
        return (None, None)
    return (H, H_inv)
set_homography = lambda ts, src_pts, dst_pts:ts.update(zip(('full_transform', 'full_transform_inv'), set_homography_core(src_pts, dst_pts)))
full_transform = set_homography_core 

# --- FONT UTILITIES ---

def load_font(font_path_or_name: str, size: int):
    """Loads a font from a file path or tries a system font name, using a cache."""
    cdef tuple key = (font_path_or_name, size)
    
    # 1. Check Cache
    if key in FONT_CACHE:
        return FONT_CACHE[key]
        
    # 2. Load if not found
    try:
        if os.path.exists(font_path_or_name):
            font_obj = ImageFont.truetype(font_path_or_name, size)
        else:
            font_obj = ImageFont.truetype(font_path_or_name, size)
    except IOError:
        print(f"Font Error: Could not load font '{font_path_or_name}'. Using default.")
        font_obj = ImageFont.load_default()
        
    # 3. Store and Return
    FONT_CACHE[key] = font_obj
    return font_obj

def text_size(text_content: str, font_info: str, size: float) -> Tuple[int, int]:
    """
    Calculates the width and height of the text block for a given font and size.
    Returns (width, height) in pixels.
    """
    if not text_content:
        return (0, 0)
    
    # Load the font object
    font_obj = load_font(font_info, int(size))
    
    # Get the bounding box: (left, top, right, bottom)
    bbox = font_obj.getbbox(text_content)
    
    # Width is right - left, Height is bottom - top
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    
    return width, height


# Missing Drawing Primitives (Python Wrappers)

# Original OpenCV text function (renamed and made internal)
cpdef void _text_cv2(np.ndarray arr, dict ts, tuple p_scr, content:str, color:Tuple, scale:float, thickness:int, bgr_color:Tuple, aa:bool = False):
    cdef double x_scr = <double>p_scr[0]
    cdef double y_scr = <double>p_scr[1]
    
    final_scale = scale * ts['size'] * 0.5 
    final_thickness = max(1, int(thickness * ts['size'] * 0.5))
    
    cv2.putText(arr, content, (int(x_scr), int(y_scr)),
        cv2.FONT_HERSHEY_SIMPLEX, final_scale, bgr_color, final_thickness, 
        lineType=_lt(aa))

# NEW Public TEXT Function (Supports Custom Fonts via PIL)
def text(arr:np.ndarray, ts:Dict, content:str, font_info:str, size:float, color:Tuple, thickness:int = 1, aa:bool = True):
    """
    Renders text at cursor_pos using a specified font. 
    If font_info is 'CV2', it uses OpenCV's default font.
    Otherwise, it uses Pillow (PIL) for custom font rendering and blits the result.
    The size is scaled by ts['size'].
    """
    cdef double x_scr, y_scr
    
    # Get screen position (C-typed for speed)
    x_scr, y_scr = transform(ts['cursor_pos'], ts)
    
    if np.isinf(x_scr):
        return
        
    bgr_color = _color_bgr(color)
    
    if font_info.upper() == 'CV2':
        # Use the Cythonized OpenCV default text function
        _text_cv2(arr, ts, (x_scr, y_scr), content, color, size, thickness, bgr_color, aa)
        return

    # --- Custom Font Rendering via PIL ---
    
    # Calculate effective font size and thickness
    font_scale = <double>ts['size']
    effective_size = int(size * font_scale)
    
    if effective_size < 1:
        return

    # Load font and determine size
    font_obj = load_font(font_info, effective_size)
    
    # Determine the dimensions needed for the text image
    text_w, text_h = text_size(content, font_info, effective_size)
    
    # Create a transparent Pillow image (RGBA)
    text_img_pil = Image.new('RGBA', (text_w + 1, text_h + 1), (0, 0, 0, 0))
    draw = ImageDraw.Draw(text_img_pil)

    # Draw the text onto the PIL image
    draw.text((0, 0), content, font=font_obj, fill=color + (255,))
    
    # Convert the PIL image to OpenCV BGR + Alpha format
    text_img_cv = np.array(text_img_pil)
    
    # Use the existing blit logic for projection and blending
    # Create a temporary transformation state to place the text image
    ts_temp = ts.copy()
    # Adjust Y position (Pillow uses top-left, we want the text to start at cursor_pos)
    ts_temp['cursor_pos'] = (ts['cursor_pos'][0], ts['cursor_pos'][1] - text_h / font_scale) 
    
    blit(arr, ts_temp, text_img_cv, (1.0 / font_scale, 1.0 / font_scale))


def blit(arr:np.ndarray, ts:Dict, src_img:np.ndarray, scale_factor:Tuple):
    """
    Draws an image (src_img) at cursor_pos, applying current transformations (rot, size, shift).
    The core logic (transforming corners, perspective warp) is Cythonized.
    """
    cdef int W = src_img.shape[1]
    cdef int H = src_img.shape[0]
    cdef double sx = <double>scale_factor[0]
    cdef double sy = <double>scale_factor[1]
    
    # Get the image anchor point (cursor_pos)
    cp = ts['cursor_pos']
    
    # Calculate destination corners in world space, scaled by scale_factor
    dest_world = (
        cp,
        (cp[0] + W * sx, cp[1]),
        (cp[0] + W * sx, cp[1] + H * sy),
        (cp[0], cp[1] + H * sy),
    )
    
    # Call the Cython core function
    warped_img = blit_core(arr, ts, src_img, dest_world)

    if warped_img is None:
        return # Transformation failed (e.g., clipped in 3D)
    
    # Blit logic to handle alpha (if the source image has 4 channels)
    if src_img.shape[2] == 4:
        # Split channels: BGR and Alpha (OpenCV operations remain fast)
        b, g, r, a = cv2.split(warped_img)
        alpha_mask = a / 255.0
        
        # BGR destination for the alpha mask
        alpha_mask_3ch = cv2.merge([alpha_mask, alpha_mask, alpha_mask])
        
        # Extract the BGR part of the warped image
        bgr_warped = cv2.merge([b, g, r])
        
        # Alpha blending: (Source * Alpha) + (Dest * (1 - Alpha))
        arr[:, :] = arr * (1.0 - alpha_mask_3ch) + bgr_warped * alpha_mask_3ch
        arr[:, :] = np.uint8(arr)
    else:
        # No alpha, just combine (simple overlay)
        arr[warped_img != 0] = warped_img[warped_img != 0]

def blit_cached(arr:np.ndarray, ts:Dict, asset_name:str, scale_factor:Tuple):
    """
    Same as blit, but loads the image from the ASSETS manager.
    """
    src_img = ASSETS.get_img(asset_name)
    if src_img is not None:
        blit(arr, ts, src_img, scale_factor)
    else:
        print(f"Error:Cached image '{asset_name}' not found.")

# Shorthand functions 
tri = lambda arr, ts, d1, d2, * a, ** kw:poly(arr, ts, (d1, d2), * a, ** kw)
quad = lambda arr, ts, d1, d2, d3, * a, ** kw:poly(arr, ts, (d1, d2, d3), * a, ** kw)

# --- Transform Utilities ---
# set_homography uses the set_homography_core function
set_homography = lambda ts, src_pts, dst_pts:ts.update(zip(('full_transform', 'full_transform_inv'), set_homography_core(src_pts, dst_pts)))
# Standard setters / getters
move = lambda ts, xy:ts.__setitem__('cursor_pos', add_tuples(ts['cursor_pos'], xy + (0.0, ) * (len(ts['cursor_pos']) - len(xy))))
shift = lambda ts, xy:ts.__setitem__('shift', add_tuples(ts['shift'], xy + (0.0, ) * (len(ts['shift']) - len(xy))))
set_shift = lambda ts, xy:ts.__setitem__('shift', xy + (0.0, ) * (len(ts['shift']) - len(xy)))
scale = lambda ts, ds:ts.__setitem__('size', ts['size'] + ds)
set_size = lambda ts, ds:ts.__setitem__('size', ds)
rotate = lambda ts, dr:ts.__setitem__('rot', ts['rot'] + dr)
set_rotate = lambda ts, dr:ts.__setitem__('rot', dr)
def set_pos(ts:Dict, xy:Tuple):
    ts['cursor_pos'] = (xy[0], xy[1], xy[2]) if ts['is_3d'] and len(xy) == 3 else (xy[0], xy[1], 0.0) if ts['is_3d'] else (xy[0], xy[1])

# --- Utilities and Command Parsing  --
# Simplified for size, relies on base Python types now
array_to_str = lambda arr:f'{arr.dtype.name}, {arr.shape}, {arr.tobytes().hex()}'
str_to_array = lambda s:np.frombuffer(bytes.fromhex(s.split(', ')[2]), dtype = s.split(', ')[0]).reshape(eval(s.split(', ')[1]))
# draw_command_convert and draw_command
def draw_command_convert(arr, ts, cmd_str:str, info:str | int):
    TC = {0:lambda x:x.lower() in ('true', '1', 't'), 1:int, 2:float, 3:lambda s:eval(f'({s.strip()})'), 10:str_to_array, 11:str}
    # UPDATED SYNTAX FOR TEXT: [text, content, font_info, size, color, thickness, aa]
    SYNTAX = {'tri':[3, 3, 1, 1, 0, 0], 'line':[3, 1, 1, 0], 'rect':[3, 1, 1, 0, 0], 'circle':[2, 1, 1, 0, 0, 2], 'clear':[3], 'move':[3], 'blit':[10, 2], 'blit_c':[11, 2], 'quad':[3, 3, 3, 1, 1, 0, 0], 'text':[11, 11, 2, 3, 1, 0], 'push_state':[], 'pop_state':[], 'set_size':[2], 'set_rotate':[2], 'set_shift':[3], 'set_cam_pos':[3], 'set_cam_rot':[3], 'set_3d_mode':[0], 'set_pos':[3], 'shift':[3], 'rotate':[2], 'scale':[2]}
    cmds = [c.strip() for c in cmd_str.split(', ')]; name = cmds[0]; exp_types = SYNTAX.get(name)
    if exp_types is None or len(cmds[1:]) != len(exp_types):
        return print(f"Error @ {info}:Cmd '{name}' {'unknown' if exp_types is None else f'expects {len(exp_types)} args, got {len(cmds[1:])}'}.")
    func = sys.modules[__name__].__dict__.get(name); result = [func]
    for arg, t_int in zip(cmds[1:], exp_types):
        try:result.append(TC[t_int](arg.strip()))
        except Exception as e:return print(f"Error @ {info}:Arg '{arg}' for '{name}' failed:{e}")
    return result
def draw_command(arr, ts, cmd_str:str, info:str | int = 'Direct Call'):
    result = draw_command_convert(arr, ts, cmd_str, info)
    if result is None:return
    func, * args = result
    try:
        if func in [clear, line, rect, circle, poly, blit, blit_cached, text]:func(arr, ts, * args)
        else:func(ts, * args)
    except Exception as e:print(f"Execution Error @ {info}:{e} in {func.__name__}(...)")
def draw_tvf(arr, ts, file_name:str):
    tvf_path = file_name + ".tvf"
    try:
        with open(tvf_path, 'r') as file:
            for i, line in enumerate(file, 1):
                cmd = line.strip()
                if cmd and not cmd.startswith('#'):draw_command(arr, ts, cmd, f"TVF '{tvf_path}' line {i}")
    except Exception as e:print(f"Error reading TVF '{tvf_path}':{e}")

# --- Input Handling ---
def on_press(key):
    try:
        key_id = key.char.lower()
        if key_id not in KEYS:
            KEYS[key_id] = True
    except AttributeError:
        key_id = str(key)
        if key_id not in KEYS:
            KEYS[key_id] = True

def on_release(key):
    global RUN
    try:
        del KEYS[key.char.lower()]
    except AttributeError:
        if key == keyboard.Key.esc:
            RUN = False
        try:
            del KEYS[str(key)]
        except KeyError:
            pass

def simulate_key_press(key: str):
    """
    Simulates a key being pressed by adding it to the global KEYS dictionary.
    The key string must be the normalized form (e.g., 'a', 'Key.space').
    """
    if len(key) == 1 and key.isalpha():
        # Handle single character keys by normalizing to lowercase
        key_id = key.lower()
    else:
        # Handle special keys or multi-character inputs (e.g., 'Key.space')
        key_id = key

    # Only set the state if the key is not already marked as pressed,
    # following the same logic as the anti-repeat fix for on_press.
    if key_id not in KEYS:
        KEYS[key_id] = True
on_click = lambda x, y, button, pressed:MOUSE_STATE['buttons'].__setitem__({'left':0, 'right':1, 'middle':2}.get(button.name), pressed)
on_scroll = lambda x, y, dx, dy:MOUSE_STATE.__setitem__('scroll', MOUSE_STATE['scroll'] + dy)
on_move = lambda x, y:globals().__setitem__('MOUSE_SCR_POS', (x, y))
def get_input(method, key = None, ts = None):
    if method == "held":
        # allow callers to pass either upper- or lower-case letters; stored keys are normalized
        if isinstance(key, str):
            if not KEYS.get('ab') == None:
             KEYS.append('AB')
            return KEYS.get(key.lower(), False)
        return KEYS.get(key, False)
    elif method == "press":
        k = cv2.waitKey(1); return "esc" if k == 27 else chr(k) if k != -1 else None
    elif method == "mouse":
        if key == "pos":
            if ts is None:raise ValueError("get_input('mouse', 'pos') requires 'ts'.")
            MOUSE_STATE['world_pos'] = inverse_transform(MOUSE_SCR_POS, ts)
            return MOUSE_STATE['world_pos']
        elif key == "buttons":
            res = tuple(MOUSE_STATE['buttons'] + [MOUSE_STATE['scroll']]); MOUSE_STATE['scroll'] = 0.0; return res
        else:raise ValueError("Invalid mouse key.")
    else:raise ValueError("Invalid method.")

# --- Function: Get current window size ---
def get_window_size(window_name:str) -> Tuple[int, int]:
    rect = cv2.getWindowImageRect(window_name)
    if rect[2] > 0 and rect[3] > 0:
        return rect[2], rect[3]
    return -1, -1

# --- Setup and Run ---
_get_win_props = lambda wi:wi if isinstance(wi, tuple) and len(wi) == 2 else ((600, 400), "PyGraph Window")
convert_win_info = lambda wi:_get_win_props(wi)[1]

def init(window_info, bg_color):
    (W, H), w_name = _get_win_props(window_info)
    cv2.namedWindow(w_name, cv2.WINDOW_NORMAL | cv2.WINDOW_KEEPRATIO)
    cv2.resizeWindow(w_name, W, H)
    canvas = np.full((H, W, 3), _color_bgr(bg_color), dtype = np.uint8)
    if not hasattr(init, 'listeners_started'):
        # Create and start pynput listeners properly. Creating the Listener object
        # alone does not start it; we must call .start() so it runs in background.
        try:
            klistener = keyboard.Listener(on_press = on_press, on_release = on_release)
            mlistener = mouse.Listener(on_move = on_move, on_click = on_click, on_scroll = on_scroll)
            # mark as daemon so they don't block exit
            try:
                klistener.daemon = True
            except Exception:
                pass
            try:
                mlistener.daemon = True
            except Exception:
                pass
            klistener.start()
            mlistener.start()
            # keep references so they don't get garbage-collected
            init._kbd_listener = klistener
            init._mouse_listener = mlistener
        except Exception as e:
            print(f"Warning: failed to start input listeners: {e}")
        init.listeners_started = True
    ts = {'rot':0.0, 'size':1.0, 'shift':(W / 2, H / 2), 'cursor_pos':(0.0, 0.0), 'full_transform':None, 'full_transform_inv':None, 
    'cam_pos_3d':(0.0, 0.0, -10.0), 'cam_rot_3d':(0.0, 0.0, 0.0), 'is_3d':False}
    return canvas, ts
def run(tick_function, window_info, bg_color, target_fps = 60, dynamic_resize = False):
    w_name = convert_win_info(window_info); canvas, ts = init(window_info, bg_color)
    bg_color_t = _color_bgr(bg_color); global RUN; target_fps += 1.5
    frame_duration, last_frame_time = 1.0 / target_fps, time.time()
    while RUN:
        start_time = time.time(); 
        # --- Dynamic Resize Logic ---
        if dynamic_resize:
            current_W, current_H = get_window_size(w_name)
            if current_W != canvas.shape[1] or current_H != canvas.shape[0]:
                if current_W > 0 and current_H > 0:
                    print(f"Resizing canvas to ({current_W}, {current_H})")
                    canvas = np.full((current_H, current_W, 3), bg_color_t, dtype = np.uint8)
                    ts['shift'] = (current_W / 2, current_H / 2)
                else:
                    RUN = False
                    break

        clear(canvas, ts, bg_color_t) 
        try:
            result = tick_function(canvas, ts) 
            if isinstance(result, tuple) and len(result) == 2:RUN, canvas = result
            elif result is False:RUN = False
        except Exception as e:print(f"Error in tick function:{e}"); RUN = False 
        cv2.imshow(w_name, canvas)
        if cv2.waitKey(1) == 27 or cv2.getWindowProperty(w_name, cv2.WND_PROP_VISIBLE) < 1:RUN = False
        elapsed = time.time() - start_time; time.sleep(max(0, frame_duration - elapsed))
        delta = time.time() - last_frame_time; fps = 1.0 / delta if delta > 0 else target_fps
        cv2.setWindowTitle(w_name, f"{w_name} | FPS:{fps:.2f}"); last_frame_time = time.time()
    cv2.destroyAllWindows()

# --- Compilation ---
def compile_project(main_file_path):
    import inspect, json, base64, zlib, shutil, tempfile, atexit
    if not os.path.exists(main_file_path):raise FileNotFoundError(f"File not found:{main_file_path}")
    base_dir, main_filename = os.path.dirname(os.path.abspath(main_file_path)), os.path.basename(main_file_path)
    output_file_path = os.path.join(base_dir, main_filename.replace('.py', '_c.py'))
    vfr_files = {'PyGraph.py':inspect.getsource(sys.modules[__name__]).encode('utf - 8')}
    for root, _, files in os.walk(base_dir):
        for fn in files:
            full_path = os.path.join(root, fn); rel_path = os.path.relpath(full_path, base_dir)
            if fn.endswith(('.pyc', '_c.py')) or fn.startswith('__pycache__') or fn == main_filename:continue
            is_text = any(rel_path.lower().endswith(ext) for ext in TEXT_FILE_EXTENSIONS) or fn.endswith('.py')
            try:vfr_files[rel_path] = open(full_path, 'rb').read()
            except Exception as e:print(f"Warning:Could not read file {rel_path}:{e}")
    vfr_files[main_filename] = open(main_file_path, 'rb').read()
    vfr = [(fn, base64.b64encode(zlib.compress(content, 9)).decode('utf - 8')) for fn, content in vfr_files.items()]
    compiled_script_content = f"""
importos,sys,tempfile,base64,zlib,json,atexit,shutil
VFR=json.loads({repr(json.dumps(vfr))})
def cleanup(d):
    try:shutil.rmtree(d) if os.path.exists(d) else None
    except:pass
def run_compiled():
    tmp_d = tempfile.mkdtemp(); atexit.register(cleanup, tmp_d); sys.path.insert(0, tmp_d)
    for fn, edata in VFR:
        try:
            fp = os.path.join(tmp_d, fn); os.makedirs(os.path.dirname(fp), exist_ok = True)
            with open(fp, 'wb') as f:f.write(zlib.decompress(base64.b64decode(edata)))
        except Exception as e:print(f"Error extracting {{fn}}:{{e}}"); return
    orig_cwd = os.getcwd(); os.chdir(tmp_d)
    try:__import__("{main_filename.replace('.py', '')}")
    except Exception as e:print(f"Runtime error:{{e}}")
    finally:os.chdir(orig_cwd)
if __name__ == "__main__":run_compiled()
"""
    with open(output_file_path, 'w') as f:f.write(compiled_script_content)
    return output_file_path

# --- Dynamic Volume Monitor and Playback ---
def _volume_monitor():
 while True:
  try:
    v = max(0.0, min(1.0, GLOBAL_VOLUME[0])); pygame.mixer.set_volume(v)
    for i in range(pygame.mixer.get_num_channels()):pygame.mixer.Channel(i).set_volume(v)
    time.sleep(0.1) 
  except Exception:break
threading.Thread(target = _volume_monitor, daemon = True).start(); print("Volume monitor thread started.")

def _play_sound_logic(sound:pygame.mixer.Sound, filename:str, start_time:float, prefix:str):
    print(f"{prefix} Playing '{filename}' starting at {start_time:.2f} seconds...")
    try:
        duration = sound.get_length(); channel = sound.play(start = start_time); channel.set_volume(GLOBAL_VOLUME[0])
        time.sleep(max(0, duration - start_time) + 0.1)
        print(f"{prefix} Playback finished."); return True
    except Exception as e:print(f"{prefix} Error playing sound:{e}"); return False
def play_sound(asset_name:str, start_time:float = 0.0):
    sound = ASSETS.get_snd(asset_name)
    if sound:_play_sound_logic(sound, asset_name, start_time, "\n[Blocking]")
    else:print(f"Error:Cached sound '{asset_name}' not found.")
def start_sound(asset_name:str, start_time:float = 0.0):
    sound = ASSETS.get_snd(asset_name)
    if sound:
        print(f"\n[Non - Blocking] Starting thread to play '{asset_name}'...");
        threading.Thread(target = _play_sound_logic, args = (sound, asset_name, start_time, "[Non - Blocking Thread]"), daemon = True).start()
        print("[Non - Blocking] Function returned immediately.")
    else:print(f"Error:Cached sound '{asset_name}' not found.")
