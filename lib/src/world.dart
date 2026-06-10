import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' hide TextStyle;
import 'config.dart';

// ─── Building metadata ────────────────────────────────────────────────────────
class BuildingData {
  final int id;
  final int x0, y0, x1, y1;
  final String type; // 'house' | 'com'
  final int floors;
  final List<({int x, int y})> doors;
  BuildingData({
    required this.id,
    required this.x0, required this.y0,
    required this.x1, required this.y1,
    required this.type,
    required this.floors,
    required this.doors,
  });
  int get w => x1 - x0;
  int get h => y1 - y0;
}

// ─── Spawn records ────────────────────────────────────────────────────────────
class SpawnRecord {
  final double x, y;
  final bool indoor;
  SpawnRecord(this.x, this.y, {this.indoor = false});
}

class ItemSpawn {
  final double x, y;
  final String type;
  ItemSpawn(this.x, this.y, this.type);
}

// ─── World ────────────────────────────────────────────────────────────────────
class World {
  final int wc; // chunk count
  final int zombieTarget;
  final int npcTarget;
  final int indoorZombieTarget;
  late final int wt; // tile extent

  late final Uint8List tiles;
  late final Uint8List interiorMask; // 0 = outside, id+1 = inside building id
  final List<BuildingData> buildings = [];
  final Map<int, int> doorToBuilding = {}; // tile-index → building id

  ({double x, double y})? exitTile;
  ({double x, double y})? playerStart;

  final List<SpawnRecord> zombieSpawns = [];
  final List<SpawnRecord> npcSpawns    = [];
  final List<ItemSpawn>   itemSpawns   = [];

  int? _lastBreakX, _lastBreakY;

  // Seeded RNG (LCG matching JS prototype)
  int _s;

  Picture? mmCache;

  World({
    int? seed,
    required this.wc,
    this.zombieTarget = 25,
    this.npcTarget = 80,
    this.indoorZombieTarget = 4,
  }) : _s = seed ?? DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF {
    wt = wc * CS;
    tiles        = Uint8List(wt * wt)..fillRange(0, wt * wt, TT.GRASS);
    interiorMask = Uint8List(wt * wt);
    _generate();
  }

  // ── RNG ──────────────────────────────────────────────────────────────────
  double rng() {
    _s = ((_s * 1664525) + 1013904223) & 0xFFFFFFFF;
    return _s / 4294967296.0;
  }
  int ri(int n) => (rng() * n).floor();
  int rb(int a, int b) => a + ri(b - a + 1);
  T pick<T>(List<T> a) => a[ri(a.length)];

  // ── Tile access ───────────────────────────────────────────────────────────
  int get(int x, int y) {
    if (x < 0 || x >= wt || y < 0 || y >= wt) return TT.WALL;
    return tiles[y * wt + x];
  }
  void set(int x, int y, int t) {
    if (x < 0 || x >= wt || y < 0 || y >= wt) return;
    tiles[y * wt + x] = t;
  }
  void fill(int x0, int y0, int x1, int y1, int t) {
    for (int y = math.max(0, y0); y < math.min(wt, y1); y++)
      for (int x = math.max(0, x0); x < math.min(wt, x1); x++)
        tiles[y * wt + x] = t;
  }

  bool isWalkable(int x, int y) => WALKABLE.contains(get(x, y));
  bool isSeeThrough(int x, int y) => SEETHR.contains(get(x, y));
  bool isInterior(int x, int y) {
    if (x < 0 || x >= wt || y < 0 || y >= wt) return false;
    return interiorMask[y * wt + x] > 0;
  }
  bool isBuildingTile(int x, int y) {
    final t = get(x, y);
    if (t != TT.BWALL && t != TT.DOOR && t != TT.WINDOW) return false;
    return (y > 0     && interiorMask[(y - 1) * wt + x] > 0) ||
           (y < wt-1  && interiorMask[(y + 1) * wt + x] > 0) ||
           (x > 0     && interiorMask[y * wt + (x - 1)] > 0) ||
           (x < wt-1  && interiorMask[y * wt + (x + 1)] > 0);
  }
  int getBuildingIdAt(int x, int y) {
    if (x < 0 || x >= wt || y < 0 || y >= wt) return -1;
    return interiorMask[y * wt + x] - 1;
  }

  bool lineOfSight(double ax, double ay, double bx, double by) {
    final dx = bx - ax, dy = by - ay;
    final steps = (math.sqrt(dx * dx + dy * dy) * 2).ceil();
    for (int i = 1; i < steps; i++) {
      final t = i / steps;
      if (!isSeeThrough((ax + dx * t).round(), (ay + dy * t).round())) return false;
    }
    return true;
  }

  // ── Generation ────────────────────────────────────────────────────────────
  void _generate() {
    _placeRoads();
    _placeCityWall();
    _placeExit();
    _placeSidewalks();
    for (int cy = 0; cy < wc; cy++)
      for (int cx = 0; cx < wc; cx++)
        _genChunk(cx, cy);
    _placeDecorations();
    _computeSpawns();
    _buildMinimap();
  }

  void _placeRoads() {
    for (int cx = 1; cx < wc; cx++) {
      final bx = cx * CS;
      fill(bx - ROAD_HALF, 0, bx + ROAD_HALF, wt, TT.ROAD);
    }
    for (int cy = 1; cy < wc; cy++) {
      final by = cy * CS;
      fill(0, by - ROAD_HALF, wt, by + ROAD_HALF, TT.ROAD);
    }
  }

  void _placeCityWall() {
    fill(0, 0, wt, WALL_T, TT.WALL);
    fill(0, wt - WALL_T, wt, wt, TT.WALL);
    fill(0, WALL_T, WALL_T, wt - WALL_T, TT.WALL);
    fill(wt - WALL_T, WALL_T, wt, wt - WALL_T, TT.WALL);
  }

  void _placeExit() {
    final idx  = rb(1, wc - 1);
    final side = ri(4);
    final ctr  = idx * CS;
    if (side == 0) {
      fill(ctr - ROAD_HALF, 0, ctr + ROAD_HALF, WALL_T, TT.EXIT);
      exitTile = (x: ctr.toDouble(), y: 1.0);
    } else if (side == 1) {
      fill(ctr - ROAD_HALF, wt - WALL_T, ctr + ROAD_HALF, wt, TT.EXIT);
      exitTile = (x: ctr.toDouble(), y: (wt - 2).toDouble());
    } else if (side == 2) {
      fill(0, ctr - ROAD_HALF, WALL_T, ctr + ROAD_HALF, TT.EXIT);
      exitTile = (x: 1.0, y: ctr.toDouble());
    } else {
      fill(wt - WALL_T, ctr - ROAD_HALF, wt, ctr + ROAD_HALF, TT.EXIT);
      exitTile = (x: (wt - 2).toDouble(), y: ctr.toDouble());
    }
  }

  void _placeSidewalks() {
    for (int y = WALL_T; y < wt - WALL_T; y++) {
      for (int x = WALL_T; x < wt - WALL_T; x++) {
        if (get(x, y) != TT.GRASS) continue;
        if ([get(x-1,y), get(x+1,y), get(x,y-1), get(x,y+1)]
            .any((t) => t == TT.ROAD)) {
          set(x, y, TT.SIDEWALK);
        }
      }
    }
  }

  ({int x0, int y0, int x1, int y1, int w, int h}) _chunkBounds(int cx, int cy) {
    final lm = cx == 0 ? WALL_T : ROAD_HALF;
    final rm = cx == wc - 1 ? WALL_T : ROAD_HALF;
    final tm = cy == 0 ? WALL_T : ROAD_HALF;
    final bm = cy == wc - 1 ? WALL_T : ROAD_HALF;
    final x0 = cx * CS + lm + 1;
    final y0 = cy * CS + tm + 1;
    final x1 = (cx + 1) * CS - rm - 1;
    final y1 = (cy + 1) * CS - bm - 1;
    return (x0: x0, y0: y0, x1: x1, y1: y1, w: x1 - x0, h: y1 - y0);
  }

  void _genChunk(int cx, int cy) {
    final b = _chunkBounds(cx, cy);
    if (b.w < 10 || b.h < 10) return;

    final ccx = (wc - 1) / 2.0;
    final ccy = (wc - 1) / 2.0;
    final maxD = math.sqrt(ccx * ccx + ccy * ccy);
    final dist = math.sqrt((cx - ccx) * (cx - ccx) + (cy - ccy) * (cy - ccy)) /
        (maxD > 0 ? maxD : 1.0);

    final r = rng();
    late String type;
    if (r < 0.05 + dist * 0.18) {
      type = 'park';
    } else if (r < 0.08 + dist * 0.1) {
      type = 'vac';
    } else {
      type = dist < 0.5 ? 'com' : 'res';
    }

    if (type == 'park') { _placePark(b.x0, b.y0, b.w, b.h); return; }
    if (type == 'vac')  return;

    final bldProb = math.max(0.18, 0.80 - dist * 0.62);
    final cols    = math.max(1, b.w ~/ 20);
    final rows    = math.max(1, b.h ~/ 20);
    final cellW   = b.w ~/ cols;
    final cellH   = b.h ~/ rows;

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        if (rng() > bldProb) continue;
        final cx2 = b.x0 + col * cellW;
        final cy2 = b.y0 + row * cellH;
        const margin = 2;
        final maxBW = math.max(10, cellW - margin * 2);
        final maxBH = math.max(8,  cellH - margin * 2);
        final bw = rb(10, math.min(22, maxBW));
        final bh = rb(8,  math.min(18, maxBH));
        final bx = cx2 + margin + ri(math.max(1, cellW - bw - margin * 2));
        final by = cy2 + margin + ri(math.max(1, cellH - bh - margin * 2));
        if (type == 'com' && dist < 0.4 && bw > 14 && bh > 12) {
          _placeBuilding(bx, by, bw, bh, floors: rb(3, 5));
        } else {
          _placeHouse(bx, by, bw, bh);
        }
      }
    }
  }

  void _placeHouse(int x, int y, int w, int h) {
    final id = buildings.length;
    final doors = <({int x, int y})>[];
    // Walls
    fill(x, y, x + w, y + 1, TT.BWALL);
    fill(x, y + h - 1, x + w, y + h, TT.BWALL);
    fill(x, y, x + 1, y + h, TT.BWALL);
    fill(x + w - 1, y, x + w, y + h, TT.BWALL);
    // Interior floor
    fill(x + 1, y + 1, x + w - 1, y + h - 1, TT.BFLOOR);
    // Windows
    set(x, y + h ~/ 2, TT.WINDOW);
    set(x + w - 1, y + h ~/ 2, TT.WINDOW);
    // Door (south)
    final dx = x + w ~/ 2 - 1;
    set(dx, y + h - 1, TT.DOOR);
    set(dx + 1, y + h - 1, TT.DOOR);
    doors.add((x: dx, y: y + h - 1));
    doors.add((x: dx + 1, y: y + h - 1));
    // Furniture
    set(x + 1, y + 1, TT.TV);
    set(x + 1, y + 3, TT.SOFA); if (w > 5) set(x + 2, y + 3, TT.SOFA);
    set(x + w - 3, y + 1, TT.KITCHEN);
    final my = y + h ~/ 2;
    set(x + w ~/ 2 - 1, my, TT.DINING);
    set(x + w ~/ 2, my, TT.DINING);
    set(x + w - 3, my + 2, TT.DESK);
    // Interior mask
    for (int iy = y + 1; iy < y + h - 1; iy++)
      for (int ix = x + 1; ix < x + w - 1; ix++)
        interiorMask[iy * wt + ix] = id + 1;
    for (final d in doors) doorToBuilding[d.y * wt + d.x] = id;
    buildings.add(BuildingData(
      id: id, x0: x, y0: y, x1: x + w, y1: y + h,
      type: 'house', floors: 0, doors: doors,
    ));
  }

  void _placeBuilding(int x, int y, int w, int h, {required int floors}) {
    final id = buildings.length;
    final doors = <({int x, int y})>[];
    fill(x, y, x + w, y + 1, TT.BWALL);
    fill(x, y + h - 1, x + w, y + h, TT.BWALL);
    fill(x, y, x + 1, y + h, TT.BWALL);
    fill(x + w - 1, y, x + w, y + h, TT.BWALL);
    fill(x + 1, y + 1, x + w - 1, y + h - 1, TT.BFLOOR);
    // Windows (several rows of windows on south face)
    for (int wx = x + 2; wx < x + w - 2; wx += 3) set(wx, y + h - 1, TT.WINDOW);
    for (int wy = y + 2; wy < y + h - 2; wy += 3) {
      set(x, wy, TT.WINDOW);
      set(x + w - 1, wy, TT.WINDOW);
    }
    // Doors
    final d1 = x + (w * 0.3).floor();
    final d2 = x + (w * 0.65).floor();
    for (final dx in [d1, d2]) {
      set(dx, y + h - 1, TT.DOOR);
      set(dx + 1, y + h - 1, TT.DOOR);
      doors.add((x: dx, y: y + h - 1));
      doors.add((x: dx + 1, y: y + h - 1));
    }
    // Elevator + stairs
    final mx = x + w ~/ 2;
    set(mx, y + 2, TT.ELEVATOR);
    set(mx - 2, y + 2, TT.STAIRS);
    // Lobby furniture
    final fy = y + (h * 0.6).floor();
    set(x + 2, fy, TT.SOFA);
    set(x + 2, fy - 2, TT.DESK);
    if (w > 18) { set(mx + 2, fy, TT.SOFA); set(mx + 2, fy - 2, TT.DESK); }
    // Interior mask
    for (int iy = y + 1; iy < y + h - 1; iy++)
      for (int ix = x + 1; ix < x + w - 1; ix++)
        interiorMask[iy * wt + ix] = id + 1;
    for (final d in doors) doorToBuilding[d.y * wt + d.x] = id;
    buildings.add(BuildingData(
      id: id, x0: x, y0: y, x1: x + w, y1: y + h,
      type: 'com', floors: floors, doors: doors,
    ));
  }

  void _placePark(int x0, int y0, int w, int h) {
    for (int iy = 0; iy < h; iy += 5)
      for (int ix = 0; ix < w; ix += 5)
        if (rng() > 0.3) {
          set(x0 + ix, y0 + iy, TT.TREE);
          if (ix > 0 && iy > 0 && rng() > 0.5)
            set(x0 + ix - 1, y0 + iy - 1, TT.TREE);
        }
  }

  void _placeDecorations() {
    // Sidewalk trees
    for (int y = 0; y < wt; y++)
      for (int x = 0; x < wt; x++)
        if (get(x, y) == TT.SIDEWALK && rng() > 0.97) set(x, y, TT.TREE);
    // Parked cars on road intersections
    for (int cx = 1; cx < wc; cx++) {
      final rx = cx * CS;
      for (int cy = 0; cy < wc; cy++) {
        for (int k = 0; k < 4; k++) {
          final carY = cy * CS + rb(ROAD_HALF + 5, CS - ROAD_HALF - 6);
          if (get(rx - 2, carY) == TT.ROAD && get(rx - 2, carY + 1) == TT.ROAD && rng() > 0.5) {
            set(rx - 2, carY, TT.CAR);
            set(rx - 2, carY + 1, TT.CAR);
          }
        }
      }
    }
    // Barrels
    for (int y = 0; y < wt; y++)
      for (int x = 0; x < wt; x++) {
        if (get(x, y) == TT.ROAD     && rng() > 0.9985) set(x, y, TT.BARREL);
        if (get(x, y) == TT.SIDEWALK && rng() > 0.993)  set(x, y, TT.BARREL);
      }
    // Crosswalks + traffic lights
    for (int cx = 1; cx < wc; cx++) {
      for (int cy = 1; cy < wc; cy++) {
        final ix = cx * CS, iy = cy * CS;
        if (get(ix + ROAD_HALF + 1, iy + ROAD_HALF + 1) == TT.SIDEWALK)
          set(ix + ROAD_HALF + 1, iy + ROAD_HALF + 1, TT.TFLIGHT);
        for (int d = -ROAD_HALF; d < ROAD_HALF; d++) {
          if (get(ix + d, iy + ROAD_HALF + 1) == TT.ROAD)
            set(ix + d, iy + ROAD_HALF + 1, TT.XWALK);
          if (get(ix + ROAD_HALF + 1, iy + d) == TT.ROAD)
            set(ix + ROAD_HALF + 1, iy + d, TT.XWALK);
        }
      }
    }
  }

  void _computeSpawns() {
    // Player start: centre road tile
    final mid = (wc ~/ 2) * CS;
    bool found = false;
    outer:
    for (int r = 0; r <= ROAD_HALF; r++) {
      for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
          if (dx.abs() != r && dy.abs() != r) continue;
          final x = mid + dx, y = mid + dy;
          if (get(x, y) == TT.ROAD) {
            if ([[-1,-1],[1,-1],[-1,1],[1,1]].every((o) =>
                WALKABLE.contains(get(x + o[0], y + o[1])))) {
              playerStart = (x: x.toDouble(), y: y.toDouble());
              found = true;
              break outer;
            }
          }
        }
      }
    }
    if (!found) playerStart = (x: mid.toDouble(), y: mid.toDouble());

    // Outdoor zombies
    final px = playerStart!.x, py = playerStart!.y;
    int outdoorZ = 0;
    int tries = 0;
    while (outdoorZ < zombieTarget && tries++ < 8000) {
      final x = WALL_T + ri(wt - WALL_T * 2);
      final y = WALL_T + ri(wt - WALL_T * 2);
      final t = get(x, y);
      // Após muitas tentativas, aceita grama também para garantir o volume.
      final ok = (t == TT.ROAD || t == TT.SIDEWALK) ||
          (tries > 4000 && t == TT.GRASS && !isInterior(x, y));
      if (ok && math.sqrt((x - px) * (x - px) + (y - py) * (y - py)) > 25) {
        zombieSpawns.add(SpawnRecord(x.toDouble(), y.toDouble()));
        outdoorZ++;
      }
    }
    // Indoor zombies
    int indoorZ = 0;
    tries = 0;
    while (indoorZ < indoorZombieTarget && tries++ < 3000) {
      final x = WALL_T + ri(wt - WALL_T * 2);
      final y = WALL_T + ri(wt - WALL_T * 2);
      if (get(x, y) == TT.BFLOOR) {
        zombieSpawns.add(SpawnRecord(x.toDouble(), y.toDouble(), indoor: true));
        indoorZ++;
      }
    }

    // NPCs sector-distributed (grass also counts — sectors in the middle of a
    // chunk often have no road at all, which used to leave them empty)
    final npcCount   = npcTarget;
    final sectorSize = math.max(14, wt ~/ math.sqrt(npcCount).ceil());
    for (int sy = WALL_T; sy < wt - WALL_T && npcSpawns.length < npcCount; sy += sectorSize) {
      for (int sx = WALL_T; sx < wt - WALL_T && npcSpawns.length < npcCount; sx += sectorSize) {
        bool placed = false;
        for (int a = 0; a < 100 && !placed; a++) {
          final x = sx + ri(sectorSize), y = sy + ri(sectorSize);
          final t = get(x, y);
          if ((t == TT.ROAD || t == TT.SIDEWALK ||
                  (t == TT.GRASS && !isInterior(x, y))) &&
              x < wt - WALL_T && y < wt - WALL_T) {
            npcSpawns.add(SpawnRecord(x.toDouble(), y.toDouble()));
            placed = true;
          }
        }
      }
    }
    // Fallback global: garante que o alvo de NPCs seja sempre atingido.
    tries = 0;
    while (npcSpawns.length < npcCount && tries++ < 8000) {
      final x = WALL_T + ri(wt - WALL_T * 2);
      final y = WALL_T + ri(wt - WALL_T * 2);
      final t = get(x, y);
      if (t == TT.ROAD || t == TT.SIDEWALK ||
          (t == TT.GRASS && !isInterior(x, y))) {
        npcSpawns.add(SpawnRecord(x.toDouble(), y.toDouble()));
      }
    }

    // Items
    const weapons = ['revolver', 'shotgun', 'rifle', 'knife'];
    const heals   = ['apple', 'chicken'];
    tries = 0;
    while (itemSpawns.where((s) => s.type != 'mapitem').length < 22 && tries++ < 5000) {
      final x = WALL_T + ri(wt - WALL_T * 2);
      final y = WALL_T + ri(wt - WALL_T * 2);
      final t = get(x, y);
      if (t == TT.ROAD || t == TT.SIDEWALK) {
        final type = rng() < 0.45 ? pick(weapons) : pick(heals);
        itemSpawns.add(ItemSpawn(x.toDouble(), y.toDouble(), type));
      }
    }
    // 3 map items spread apart
    tries = 0;
    while (itemSpawns.where((s) => s.type == 'mapitem').length < 3 && tries++ < 3000) {
      final x = WALL_T + ri(wt - WALL_T * 2);
      final y = WALL_T + ri(wt - WALL_T * 2);
      final t = get(x, y);
      if ((t == TT.ROAD || t == TT.SIDEWALK || t == TT.GRASS) &&
          itemSpawns.where((s) => s.type == 'mapitem').every((m) =>
              math.sqrt((m.x - x) * (m.x - x) + (m.y - y) * (m.y - y)) > 35)) {
        itemSpawns.add(ItemSpawn(x.toDouble(), y.toDouble(), 'mapitem'));
      }
    }
  }

  void _buildMinimap() {
    const double MM = 192.0;
    final recorder = PictureRecorder();
    final canvas   = Canvas(recorder, Rect.fromLTWH(0, 0, MM, MM));
    final paint    = Paint();
    final scale    = MM / wt;

    final Map<int, Color> pal = {
      TT.GRASS:    const Color(0xFF3c8234),
      TT.ROAD:     const Color(0xFF64646c),
      TT.SIDEWALK: const Color(0xFF8c8c94),
      TT.WALL:     const Color(0xFF383838),
      TT.EXIT:     const Color(0xFF00dc5a),
      TT.BWALL:    const Color(0xFFc8c4be),
      TT.BFLOOR:   const Color(0xFFc8c4be),
      TT.TREE:     const Color(0xFF1e6e1c),
      TT.BARREL:   const Color(0xFF78581e),
      TT.CAR:      const Color(0xFFc83232),
      TT.DOOR:     const Color(0xFF784820),
      TT.WINDOW:   const Color(0xFFc8c4be),
      TT.MAPITEM:  const Color(0xFFffdc00),
    };

    for (int ty = 0; ty < wt; ty++) {
      for (int tx = 0; tx < wt; tx++) {
        int tile = get(tx, ty);
        if (isInterior(tx, ty) || isBuildingTile(tx, ty)) tile = TT.BWALL;
        paint.color = pal[tile] ?? const Color(0xFF3c8234);
        canvas.drawRect(
          Rect.fromLTWH(tx * scale, ty * scale,
              math.max(0.5, scale), math.max(0.5, scale)),
          paint,
        );
      }
    }
    mmCache = recorder.endRecording();
  }
}
