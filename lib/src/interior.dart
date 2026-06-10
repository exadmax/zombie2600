import 'dart:math' as math;
import 'dart:typed_data';
import 'config.dart';
import 'world.dart' show BuildingData;

// ─── Interior layout ──────────────────────────────────────────────────────────
class Layout {
  final int W, H;
  final Uint8List tiles;
  final List<({double x, double y, String type})> exits;
  final ({double x, double y}) entry;
  Layout({
    required this.W,
    required this.H,
    required this.tiles,
    required this.exits,
    required this.entry,
  });
  int get(int x, int y) {
    if (x < 0 || x >= W || y < 0 || y >= H) return TT.BWALL;
    return tiles[y * W + x];
  }
}

// ─── Interior ─────────────────────────────────────────────────────────────────
class Interior {
  final BuildingData building;
  final String type;
  final int numFloors;
  int currentFloor = 0;
  late final List<Layout> layouts;

  Interior(this.building)
      : type = building.type,
        numFloors = building.type == 'house' ? 0 : (building.floors) {
    layouts = [];
    _generate();
  }

  int _rs = 0;
  double _rng() {
    _rs = ((_rs * 1664525) + 1013904223) & 0xFFFFFFFF;
    return _rs / 4294967296.0;
  }
  int _ri(int n) => (_rng() * n).floor();

  void _generate() {
    _rs = (building.id * 31337 + 12345) & 0xFFFFFFFF;
    if (type == 'house') {
      layouts.add(_genHouse());
    } else {
      layouts.add(_genLobby());
      for (int f = 1; f <= numFloors; f++) layouts.add(_genFloor(f));
    }
  }

  Layout getLayout([int? floor]) {
    final f = floor ?? currentFloor;
    return layouts[f.clamp(0, layouts.length - 1)];
  }

  bool isWalkable(double x, double y) {
    final lay = getLayout();
    final ix = x.floor(), iy = y.floor();
    if (ix < 0 || ix >= lay.W || iy < 0 || iy >= lay.H) return false;
    return WALKABLE.contains(lay.tiles[iy * lay.W + ix]);
  }
  bool isSeeThrough(double x, double y) {
    final lay = getLayout();
    final ix = x.floor(), iy = y.floor();
    if (ix < 0 || ix >= lay.W || iy < 0 || iy >= lay.H) return false;
    return SEETHR.contains(lay.tiles[iy * lay.W + ix]);
  }
  int get(double x, double y) {
    final lay = getLayout();
    final ix = x.floor(), iy = y.floor();
    if (ix < 0 || ix >= lay.W || iy < 0 || iy >= lay.H) return TT.BWALL;
    return lay.tiles[iy * lay.W + ix];
  }
  bool lineOfSight(double ax, double ay, double bx, double by) {
    final dx = bx - ax, dy = by - ay;
    final steps = (math.sqrt(dx * dx + dy * dy) * 2).ceil();
    for (int i = 1; i < steps; i++) {
      final t = i / steps;
      if (!isSeeThrough(ax + dx * t, ay + dy * t)) return false;
    }
    return true;
  }
  ({double x, double y, String type})? getExitAt(double x, double y) {
    final lay = getLayout();
    for (final e in lay.exits) {
      if ((e.x - x).abs() < 0.85 && (e.y - y).abs() < 0.85) return e;
    }
    return null;
  }
  List<({int x, int y})> getWalkableSpots([int floorIdx = 0]) {
    final lay = getLayout(floorIdx);
    final spots = <({int x, int y})>[];
    for (int y = 1; y < lay.H - 1; y++)
      for (int x = 1; x < lay.W - 1; x++)
        if (WALKABLE.contains(lay.tiles[y * lay.W + x])) spots.add((x: x, y: y));
    return spots;
  }

  // ── House: single room ──────────────────────────────────────────────────────
  Layout _genHouse() {
    const W = 18, H = 14;
    final t = Uint8List(W * H)..fillRange(0, W * H, TT.BFLOOR);
    void s(int x, int y, int v) { if (x >= 0 && x < W && y >= 0 && y < H) t[y * W + x] = v; }

    for (int x = 0; x < W; x++) { s(x, 0, TT.BWALL); s(x, H - 1, TT.BWALL); }
    for (int y = 0; y < H; y++) { s(0, y, TT.BWALL); s(W - 1, y, TT.BWALL); }

    final dx = W ~/ 2 - 1;
    s(dx, H - 1, TT.DOOR); s(dx + 1, H - 1, TT.DOOR);
    s(0, H ~/ 2, TT.WINDOW); s(W - 1, H ~/ 2, TT.WINDOW); s(W ~/ 2, 0, TT.WINDOW);

    s(1, 1, TT.TV);
    s(1, 3, TT.SOFA); s(2, 3, TT.SOFA); s(3, 3, TT.SOFA);
    s(W - 3, 1, TT.KITCHEN); s(W - 2, 1, TT.KITCHEN);
    final my = H ~/ 2;
    s(W ~/ 2 - 1, my, TT.DINING); s(W ~/ 2, my, TT.DINING);
    s(W - 3, my + 2, TT.DESK);

    return Layout(
      W: W, H: H, tiles: t,
      exits: [
        (x: dx.toDouble(),     y: (H - 1).toDouble(), type: 'world'),
        (x: (dx + 1).toDouble(), y: (H - 1).toDouble(), type: 'world'),
        (x: dx.toDouble(),     y: (H - 2).toDouble(), type: 'world'),
        (x: (dx + 1).toDouble(), y: (H - 2).toDouble(), type: 'world'),
      ],
      entry: (x: dx.toDouble(), y: (H - 3).toDouble()),
    );
  }

  // ── Building lobby ──────────────────────────────────────────────────────────
  Layout _genLobby() {
    const W = 22, H = 16;
    final t = Uint8List(W * H)..fillRange(0, W * H, TT.BFLOOR);
    void s(int x, int y, int v) { if (x >= 0 && x < W && y >= 0 && y < H) t[y * W + x] = v; }

    for (int x = 0; x < W; x++) { s(x, 0, TT.BWALL); s(x, H - 1, TT.BWALL); }
    for (int y = 0; y < H; y++) { s(0, y, TT.BWALL); s(W - 1, y, TT.BWALL); }

    final d1 = (W * 0.3).floor(), d2 = (W * 0.7).floor();
    s(d1, H - 1, TT.DOOR); s(d1 + 1, H - 1, TT.DOOR);
    s(d2, H - 1, TT.DOOR); s(d2 + 1, H - 1, TT.DOOR);

    for (int y = 3; y < H - 2; y += 4) { s(0, y, TT.WINDOW); s(W - 1, y, TT.WINDOW); }
    s(2, 1, TT.STAIRS); s(3, 1, TT.STAIRS); s(2, 2, TT.STAIRS); s(3, 2, TT.STAIRS);
    s(W - 5, 1, TT.STAIRS); s(W - 4, 1, TT.STAIRS);
    s(W ~/ 2, 1, TT.ELEVATOR);

    return Layout(
      W: W, H: H, tiles: t,
      exits: [
        (x: d1.toDouble(),     y: (H - 1).toDouble(), type: 'world'),
        (x: (d1+1).toDouble(), y: (H - 1).toDouble(), type: 'world'),
        (x: d2.toDouble(),     y: (H - 1).toDouble(), type: 'world'),
        (x: (d2+1).toDouble(), y: (H - 1).toDouble(), type: 'world'),
        (x: 2.5,               y: 1.5,                type: 'up'),
        (x: (W - 4.0),         y: 1.5,                type: 'up'),
      ],
      entry: (x: d1.toDouble(), y: (H - 3).toDouble()),
    );
  }

  // ── Upper floor with 2 apartments ──────────────────────────────────────────
  Layout _genFloor(int floorNum) {
    const W = 22, H = 16;
    final t = Uint8List(W * H)..fillRange(0, W * H, TT.BFLOOR);
    void s(int x, int y, int v) { if (x >= 0 && x < W && y >= 0 && y < H) t[y * W + x] = v; }

    for (int x = 0; x < W; x++) { s(x, 0, TT.BWALL); s(x, H - 1, TT.BWALL); }
    for (int y = 0; y < H; y++) { s(0, y, TT.BWALL); s(W - 1, y, TT.BWALL); }

    // Dividing wall with door
    for (int y = 1; y < H - 1; y++) s(W ~/ 2, y, TT.BWALL);
    final midDoor = H ~/ 2;
    s(W ~/ 2, midDoor, TT.DOOR);

    // Stairs (both sides)
    s(2, 1, TT.STAIRS); s(3, 1, TT.STAIRS);
    s(W - 5, 1, TT.STAIRS); s(W - 4, 1, TT.STAIRS);
    s(W ~/ 2, 1, TT.ELEVATOR);

    // Apartment A furniture (left)
    s(1, 3, TT.SOFA); s(2, 3, TT.SOFA);
    s(1, 5, TT.TV);
    s(W ~/ 2 - 3, 2, TT.KITCHEN);
    s(W ~/ 2 - 4, H ~/ 2, TT.DINING); s(W ~/ 2 - 3, H ~/ 2, TT.DINING);
    s(2, H - 3, TT.DESK);

    // Apartment B furniture (right)
    s(W - 3, 3, TT.SOFA); s(W - 4, 3, TT.SOFA);
    s(W - 3, 5, TT.TV);
    s(W ~/ 2 + 2, 2, TT.KITCHEN);
    s(W ~/ 2 + 2, H ~/ 2, TT.DINING); s(W ~/ 2 + 3, H ~/ 2, TT.DINING);
    s(W - 3, H - 3, TT.DESK);

    // Windows
    for (int y = 2; y < H - 1; y += 4) { s(0, y, TT.WINDOW); s(W - 1, y, TT.WINDOW); }

    // Higher floors have more items
    if (floorNum >= 3) {
      s(_ri(W ~/ 2 - 4) + 2, _ri(H - 4) + 2, TT.MAPITEM);
    }

    return Layout(
      W: W, H: H, tiles: t,
      exits: [
        // Escadas da esquerda sobem; as da direita descem.
        (x: 2.5,         y: 1.5, type: 'up'),
        (x: (W - 4.0),   y: 1.5, type: 'down'),
      ],
      entry: (x: 2.5, y: 3.5),
    );
  }
}
