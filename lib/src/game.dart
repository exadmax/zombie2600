import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'config.dart';
import 'sprites.dart';
import 'world.dart';
import 'interior.dart';
import 'entities.dart';

// ─── Game state enumeration ───────────────────────────────────────────────────
enum GameState { title, playing, gameover, victory }

// ─── Per-phase stats for victory screen ──────────────────────────────────────
class PhaseStats {
  int killCount    = 0;
  bool sawInfection = false;
  int maxChasers   = 0;
  bool hadHorde    = false;
}

// ─── Main game logic container ────────────────────────────────────────────────
class Game {
  GameState state = GameState.title;

  World?  world;
  Player? player;
  List<Zombie>   zombies  = [];
  List<NPC>      npcs     = [];
  List<GameItem> items    = [];
  List<Zombie>   interiorZombies = [];
  // Liga cada zumbi do interior ao seu correspondente no mundo, para que
  // mortes dentro do prédio persistam ao sair/reentrar.
  final Map<Zombie, Zombie> interiorTwin = {};

  ({double x, double y}) cam = (x: 0.0, y: 0.0);
  InputState input   = InputState();

  ({int buildingId, Interior interior})? insideBuilding;

  int phase   = 1;
  int worldWC = GAME.baseWorldWC;
  bool hasMap = false;

  PhaseStats stats   = PhaseStats();
  int  popupTimer    = 0;
  String popupMsg    = '';
  double stepTimer   = 0;

  // ms elapsed since app start (passed in each update)
  int now = 0;

  bool enterLock = false;

  void startGame(bool isNewPhase) {
    if (!isNewPhase) {
      phase   = 1;
      worldWC = GAME.baseWorldWC;
    }
    world = World(
      wc: worldWC,
      zombieTarget:       GAME.zombiesForPhase(phase),
      npcTarget:          GAME.npcsForPhase(phase),
      indoorZombieTarget: GAME.indoorZombiesForPhase(phase),
    );
    final ws = world!;

    if (isNewPhase && player != null) {
      player!.hearts = player!.maxHearts;
      player!.x      = ws.playerStart!.x;
      player!.y      = ws.playerStart!.y;
      player!.alertLevel  = 0;
      player!.soundRadius = 0;
      player!.vx = 0; player!.vy = 0;
    } else {
      player = Player(ws.playerStart!.x, ws.playerStart!.y);
      hasMap = false;
    }

    zombies = ws.zombieSpawns
        .map((s) => Zombie(s.x, s.y, breakoutMode: s.indoor))
        .toList();
    npcs  = ws.npcSpawns.map((s) => NPC(s.x, s.y)).toList();
    items = ws.itemSpawns.map((s) => GameItem(s.x, s.y, s.type)).toList();

    insideBuilding = null;
    interiorZombies = [];
    interiorTwin.clear();
    enterLock = false;
    stepTimer = 0;
    stats = PhaseStats();
    state = GameState.playing;
    _updateCamera();
  }

  void nextPhase() {
    phase++;
    if (phase % 2 == 0 && worldWC < GAME.maxWorldWC) worldWC++;
    startGame(true);
  }

  void update(double dt) {
    now += (dt * 1000).round();
    final ms = dt * 1000;

    if (state != GameState.playing) return;

    final p = player!;
    final w = world!;

    if (insideBuilding != null) {
      _updateInterior(dt, ms);
    } else {
      _updateWorld(dt, ms, p, w);
    }
  }

  void _updateCamera() {
    final p = player;
    if (p == null) return;
    // Will be finished in rendering
  }

  void _popup(String msg) { popupMsg = msg; popupTimer = 1500; }

  void _updateWorld(double dt, double ms, Player p, World w) {
    final wa = worldAdapter(w);
    p.update(dt, input, wa, now);
    // Camera
    cam = (x: p.x - 0, y: p.y - 0); // raw; rendering centres it

    stepTimer -= ms;
    if ((p.vx != 0 || p.vy != 0) && stepTimer <= 0) stepTimer = GAME.soundWalkCd.toDouble();

    for (final z in zombies) {
      if (!z.alive) continue;
      z.update(dt, p, wa, npcs, now);
      // Door-break callback
      // (simplified: no door break propagation in this port)
    }

    // NPCs
    for (int i = npcs.length - 1; i >= 0; i--) {
      final npc = npcs[i];
      if (!npc.alive) continue;
      if (math.sqrt((npc.x - p.x) * (npc.x - p.x) + (npc.y - p.y) * (npc.y - p.y)) > CS * 4) continue;
      npc.update(dt, zombies, wa);
      if (npc.infected && !npc.infSoundPlayed) {
        npc.infSoundPlayed = true;
        stats.sawInfection = true;
        _popup('INFECTADO!');
      }
      if (npc.infected && npc.infectionTimer <= 0) {
        final z = Zombie(npc.x, npc.y);
        z.state = 'alert';
        z.alertTarget = (x: p.x, y: p.y);
        z.alertTimer  = GAME.zombieAlertDecay.toDouble();
        zombies.add(z);
        npcs.removeAt(i);
      }
    }

    if (p.atkJustFired) _handleAttack(zombies);

    for (final item in items) {
      if (!item.collected) {
        final d = math.sqrt((p.x - item.x) * (p.x - item.x) + (p.y - item.y) * (p.y - item.y));
        if (d < 0.9) _collect(item);
      }
    }

    _checkBuildingEntry();

    int maxAlert = 0, chasers = 0;
    for (final z in zombies) {
      if (!z.alive) continue;
      if (z.state == 'chase') { maxAlert = 2; chasers++; }
      else if (z.state == 'alert') maxAlert = math.max(maxAlert, 1);
    }
    if (chasers > stats.maxChasers) stats.maxChasers = chasers;
    if (chasers >= 3) stats.hadHorde = true;
    p.alertLevel = maxAlert;

    if (popupTimer > 0) popupTimer -= ms.round();

    if (!p.alive) { state = GameState.gameover; return; }

    final et = w.exitTile;
    if (et != null) {
      final d = math.sqrt((p.x - et.x) * (p.x - et.x) + (p.y - et.y) * (p.y - et.y));
      if (d < 2.5) state = GameState.victory;
    }
  }

  void _updateInterior(double dt, double ms) {
    final p     = player!;
    final info  = insideBuilding!;
    final inter = info.interior;
    final ia    = interiorAdapter(inter);

    p.update(dt, input, ia, now);

    stepTimer -= ms;
    if ((p.vx != 0 || p.vy != 0) && stepTimer <= 0) stepTimer = GAME.soundWalkCd.toDouble();

    for (final z in interiorZombies) {
      if (!z.alive) continue;
      z.update(dt, p, ia);
    }

    if (p.atkJustFired) _handleAttack(interiorZombies);

    if (popupTimer > 0) popupTimer -= ms.round();
    if (!p.alive) { state = GameState.gameover; return; }

    // Check exit
    final lay = inter.getLayout();
    final tile = inter.get(p.x, p.y);
    if (tile == TT.DOOR || tile == TT.STAIRS || tile == TT.ELEVATOR) {
      final ex = inter.getExitAt(p.x, p.y);
      if (ex != null && !enterLock) {
        if (ex.type == 'world') {
          // Exit to world: reposition just outside the building door
          final bld = world!.buildings[info.buildingId];
          if (bld.doors.isNotEmpty) {
            final d = bld.doors.first;
            p.x = d.x + 0.5;
            p.y = d.y + 1.5;
          }
          insideBuilding = null;
          interiorZombies.clear();
          interiorTwin.clear();
          enterLock = true;
          _popup('← SAINDO');
        } else if (ex.type == 'up') {
          if (inter.currentFloor < inter.numFloors) {
            inter.currentFloor++;
            p.x = 2.5; p.y = 3.5;
            enterLock = true;
            _popup('${inter.currentFloor}º ANDAR');
          }
        } else if (ex.type == 'down') {
          if (inter.currentFloor > 0) {
            inter.currentFloor--;
            p.x = lay.W - 4.0; p.y = 3.5;
            enterLock = true;
            _popup(inter.currentFloor == 0
                ? 'LOBBY'
                : '${inter.currentFloor}º ANDAR');
          }
        }
      }
    } else {
      enterLock = false;
    }
  }

  void _handleAttack(List<Zombie> zList) {
    final p = player!;
    for (final z in zList) {
      if (!z.alive) continue;
      final d = math.sqrt((p.x - z.x) * (p.x - z.x) + (p.y - z.y) * (p.y - z.y));
      if (d < GAME.playerAttackRange) {
        final dmg = p.weapon == 'revolver' ? 1 :
                    p.weapon == 'shotgun'  ? 3 :
                    p.weapon == 'rifle'    ? 3 : 1;
        // Knife at very close range only
        if (p.weapon == 'knife' && d > GAME.knifeRiskRange) {
          p.takeDamage(); // missed
          continue;
        }
        z.hp -= dmg;
        if (z.hp <= 0) {
          z.alive = false;
          interiorTwin[z]?.alive = false;
          stats.killCount++;
          p.gainScore(GAME.scorePerKill);
          _popup('+${GAME.scorePerKill}');
        }
        // Consume ammo for ranged
        if (p.weapon != 'knife') {
          p.ammo[p.weapon] = (p.ammo[p.weapon] ?? 0) - 1;
          if ((p.ammo[p.weapon] ?? 0) <= 0) {
            p.weapons.remove(p.weapon);
            p.weapon = 'knife';
          }
        }
      }
    }
  }

  void _collect(GameItem item) {
    item.collected = true;
    final p = player!;
    switch (item.type) {
      case 'apple':    p.heal(1); _popup('+1 ♥'); break;
      case 'chicken':  p.heal(3); _popup('♥♥♥'); break;
      case 'mapitem':
        p.gainScore(GAME.scoreMapItem);
        hasMap = true;
        _popup('MAPA +${GAME.scoreMapItem}');
        break;
      case 'revolver':
      case 'shotgun':
      case 'rifle':
      case 'knife':
        final ammoMap = {'revolver': 12, 'shotgun': 6, 'rifle': 8, 'knife': 0};
        p.weapons.add(item.type);
        p.ammo[item.type] = (p.ammo[item.type] ?? 0) + (ammoMap[item.type] ?? 0);
        _popup(item.type.toUpperCase());
        break;
    }
  }

  void _checkBuildingEntry() {
    if (!input.up) { enterLock = false; return; }
    if (enterLock) return;
    final p = player!;
    final w = world!;

    final tx = p.x.floor(), ty = p.y.floor();
    // Check tiles around player for doors
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final nx = tx + dx, ny = ty + dy;
        if (w.get(nx, ny) != TT.DOOR) continue;
        final bldId = w.doorToBuilding[ny * w.wt + nx];
        if (bldId == null) continue;
        final bld = w.buildings[bldId];
        final interior = Interior(bld);
        // Transfer indoor zombies — scatter across walkable interior spots
        final walkable = interior.getWalkableSpots();
        final matching = zombies
            .where((z) => z.alive && w.getBuildingIdAt(z.x.floor(), z.y.floor()) == bldId)
            .toList();
        interiorZombies = [];
        interiorTwin.clear();
        for (int idx = 0; idx < matching.length; idx++) {
          final spot = walkable.isNotEmpty
              ? walkable[idx % walkable.length]
              : (x: 3, y: 3);
          final iz = Zombie(spot.x.toDouble(), spot.y.toDouble(),
              breakoutMode: false);
          interiorTwin[iz] = matching[idx];
          interiorZombies.add(iz);
        }
        // Place player at entry
        final entry = interior.getLayout().entry;
        p.x = entry.x; p.y = entry.y;
        insideBuilding = (buildingId: bldId, interior: interior);
        enterLock = true;
        _popup('▲ INTERIOR');
        return;
      }
    }
  }

  // ─── Rendering ──────────────────────────────────────────────────────────────
  void render(Canvas canvas, Size size) {
    if (state == GameState.title) { _drawTitle(canvas, size); return; }
    if (state == GameState.gameover) {
      if (world != null) {
        if (insideBuilding != null) _renderInterior(canvas, size);
        else _renderWorld(canvas, size);
      }
      _drawGameOver(canvas, size);
      return;
    }
    if (state == GameState.victory) { _drawVictory(canvas, size); return; }
    if (insideBuilding != null) _renderInterior(canvas, size);
    else _renderWorld(canvas, size);
  }

  // ── World rendering ────────────────────────────────────────────────────────
  void _renderWorld(Canvas canvas, Size size) {
    final w  = world!;
    final p  = player!;
    final cw = size.width, ch = size.height;

    // Centre camera on player
    final camX = p.x - cw / (TS * 2);
    final camY = p.y - ch / (TS * 2);
    cam = (x: camX, y: camY);

    // Background
    canvas.drawRect(Rect.fromLTWH(0, 0, cw, ch), Paint()..color = CLR.bg);

    // Tile range
    final tx0 = math.max(0, camX.floor() - 1);
    final ty0 = math.max(0, camY.floor() - 1);
    final tx1 = math.min(w.wt, (camX + cw / TS).ceil() + 1);
    final ty1 = math.min(w.wt, (camY + ch / TS).ceil() + 1);

    // Draw tiles
    for (int ty = ty0; ty < ty1; ty++) {
      for (int tx = tx0; tx < tx1; tx++) {
        final sx = (tx - camX) * TS, sy = (ty - camY) * TS;
        _drawTile(canvas, w, tx, ty, sx, sy, TS);
      }
    }

    // Building facades
    _renderBuildings(canvas, w, cam, cw, ch);

    // Items
    for (final item in items) item.draw(canvas, cam, cw, ch, now);

    // NPCs
    for (final npc in npcs) if (npc.alive) npc.draw(canvas, cam, cw, ch, now);

    // Zombies
    for (final z in zombies) z.draw(canvas, cam, cw, ch, now);

    // Player
    p.draw(canvas, cam, cw, ch, now);

    // Exit arrow/glow
    _renderExitIndicator(canvas, w, cam, cw, ch);

    // Sound ring
    if (p.soundRadius > 0) {
      canvas.drawCircle(
        Offset((p.x - camX) * TS + TS / 2, (p.y - camY) * TS + TS / 2),
        p.soundRadius * TS,
        Paint()..color = CLR.soundRing,
      );
    }

    // Minimap
    if (hasMap) {
      _renderMinimap(canvas, w, cam, cw, ch);
    } else {
      _renderMinimapLocked(canvas, cw, ch);
    }

    // HUD
    _renderHUD(canvas, size);

    // Popup
    _renderPopup(canvas, p, cam, false, size);
  }

  // ── Interior rendering ─────────────────────────────────────────────────────
  void _renderInterior(Canvas canvas, Size size) {
    final info  = insideBuilding!;
    final inter = info.interior;
    final lay   = inter.getLayout();
    final p     = player!;
    final cw    = size.width, ch    = size.height;

    canvas.drawRect(Rect.fromLTWH(0, 0, cw, ch),
        Paint()..color = const Color(0xFF0d0a06));

    final offX = ((cw - lay.W * TSI) / 2).floorToDouble();
    final offY = ((ch - lay.H * TSI) / 2).floorToDouble();
    final off  = (x: offX, y: offY);

    // Tiles
    for (int ty = 0; ty < lay.H; ty++) {
      for (int tx = 0; tx < lay.W; tx++) {
        final sx = offX + tx * TSI, sy = offY + ty * TSI;
        _drawTileInterior(canvas, lay.get(tx, ty), sx, sy);
      }
    }

    // Entities
    for (final z in interiorZombies) z.drawInterior(canvas, off, now);
    p.drawInterior(canvas, off);

    // HUD
    _renderHUD(canvas, size);
    _renderPopup(canvas, p, cam, true, size);

    // Floor/building label
    final bld = world!.buildings[info.buildingId];
    final floorLabel = inter.currentFloor == 0
        ? (bld.type == 'house' ? 'INTERIOR DA CASA' : 'LOBBY')
        : '${inter.currentFloor}º ANDAR';
    final labelBg = Paint()..color = const Color(0xB3000014);
    canvas.drawRect(
        Rect.fromLTWH(cw / 2 - 100, 8, 200, 28), labelBg);
    drawText(canvas, floorLabel, cw / 2, 12,
        const Color(0xFF4a6abb), 13, bold: true, align: 'center');
    drawText(canvas, 'Portas · Sair   Escadas Esq · Subir   Escadas Dir · Descer',
        cw / 2, ch - 20, const Color(0xFF222222), 10, align: 'center');
  }

  // ── Tile drawing ───────────────────────────────────────────────────────────
  void _drawTile(Canvas canvas, World w, int tx, int ty,
      double sx, double sy, double size) {
    final tile = w.get(tx, ty);
    // Skip tiles covered by building interior (will be drawn as roof)
    if (w.isInterior(tx, ty)) return;
    _paintTile(canvas, tile, tx, ty, sx, sy, size);
  }

  void _paintTile(Canvas canvas, int tile, int tx, int ty,
      double sx, double sy, double size) {
    switch (tile) {
      case TT.GRASS:
        fillRect(canvas, sx, sy, size, size,
            (tx + ty) % 3 == 0 ? CLR.grassAlt : CLR.grass);
        break;
      case TT.ROAD:
        fillRect(canvas, sx, sy, size, size, CLR.road);
        fillRect(canvas, sx, sy, 1, size, const Color(0x12000000));
        fillRect(canvas, sx, sy, size, 1, const Color(0x12000000));
        break;
      case TT.SIDEWALK:
        fillRect(canvas, sx, sy, size, size, CLR.sidewalk);
        fillRect(canvas, sx, sy + size - 1, size, 1, CLR.sidewalkEdge);
        fillRect(canvas, sx + size - 1, sy, 1, size, CLR.sidewalkEdge);
        break;
      case TT.WALL:
        fillRect(canvas, sx, sy, size, size, CLR.wall);
        fillRect(canvas, sx, sy, size, 3, CLR.wallTop);
        final row = ty ~/ 2;
        final off = (row % 2) * 8;
        for (double bx = off - 8; bx < size + 8; bx += 16) {
          fillRect(canvas, sx + bx, sy + size / 2, 1, size / 2,
              const Color(0x1E000000));
        }
        fillRect(canvas, sx, sy + size / 2, size, 1,
            const Color(0x1E000000));
        break;
      case TT.EXIT:
        fillRect(canvas, sx, sy, size, size, CLR.exitColor);
        final p2 = (math.sin(now / 260.0) + 1) / 2;
        fillRect(canvas, sx, sy, size, size,
            CLR.exitGlow.withOpacity(0.2 + p2 * 0.4));
        break;
      case TT.BWALL:
        final g = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bwall[g]);
        fillRect(canvas, sx + size - 2, sy, 2, size, const Color(0x26000000));
        fillRect(canvas, sx, sy + size - 2, size, 2, const Color(0x26000000));
        fillRect(canvas, sx, sy, size, 1, const Color(0x1FFFFFFF));
        break;
      case TT.BFLOOR:
        final g2 = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[g2]);
        if ((tx + ty) % 4 == 0) {
          fillRect(canvas, sx, sy, size, 1, const Color(0x0D000000));
          fillRect(canvas, sx, sy, 1, size, const Color(0x0D000000));
        }
        break;
      case TT.DOOR:
        final g3 = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bwall[g3]);
        fillRect(canvas, sx + 2, sy + 1, size - 4, size - 1, CLR.door);
        fillRect(canvas, sx + 4, sy + 3, size - 8, size - 6, CLR.doorPanel);
        fillRect(canvas, sx + size - 6, sy + size / 2 - 1, 2, 2,
            const Color(0xFFd4a030));
        break;
      case TT.WINDOW:
        final g4 = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bwall[g4]);
        fillRect(canvas, sx + 2, sy + 2, size - 4, size - 4, CLR.windowBg);
        fillRect(canvas, sx + 3, sy + 3, size - 6, size - 6, CLR.window);
        fillRect(canvas, sx + 3, sy + 3, size - 8, 3, CLR.windowShine);
        break;
      case TT.TREE:
        fillRect(canvas, sx, sy, size, size, CLR.grass);
        fillEllipse(canvas, sx + size / 2 + 2, sy + size / 2 + 2,
            size / 2 - 1, size / 2 - 1, const Color(0x2E000000));
        fillCircle(canvas, sx + size / 2, sy + size / 2, size / 2 - 1, CLR.tree);
        fillCircle(canvas, sx + size / 2, sy + size / 2, size / 2 - 3, CLR.treeMid);
        fillCircle(canvas, sx + size / 2 - 1, sy + size / 2 - 2, size / 3, CLR.treeTop);
        fillCircle(canvas, sx + size / 2 - 2, sy + size / 2 - 3, size / 5, CLR.treeShin);
        break;
      case TT.BARREL:
        fillRect(canvas, sx, sy, size, size, CLR.sidewalk);
        fillRect(canvas, sx + 2, sy + 2, size - 4, size - 4, CLR.barrel);
        fillRect(canvas, sx + 3, sy + 3, size - 6, 2, CLR.barrelHl);
        fillRect(canvas, sx + 3, sy + size - 5, size - 6, 2, CLR.barrelHl);
        break;
      case TT.CAR:
        fillRect(canvas, sx, sy, size, size, CLR.road);
        final ci = ((tx * 7 + ty * 13) ^ (tx >> 2)) % CLR.car.length;
        fillRect(canvas, sx + 1, sy + 1, size - 2, size - 2, CLR.car[ci]);
        fillRect(canvas, sx + 2, sy + 2, size - 4, 4,
            const Color(0x73C8E6FF));
        break;
      case TT.XWALK:
        fillRect(canvas, sx, sy, size, size, CLR.road);
        if ((tx + ty) % 2 == 0) {
          fillRect(canvas, sx + 1, sy + 2, size - 2, size - 4, CLR.xwalkLine);
        }
        break;
      case TT.TFLIGHT:
        fillRect(canvas, sx, sy, size, size, CLR.sidewalk);
        fillRect(canvas, sx + 4, sy + 1, size - 8, size - 2, CLR.tflight);
        final phase = (now ~/ 3000) % 2;
        fillRect(canvas, sx + 5, sy + size - 5, size - 10, 3,
            phase == 0
                ? const Color(0xFF00cc00)
                : const Color(0xFF440000));
        fillRect(canvas, sx + 5, sy + 2, size - 10, 3,
            phase == 1
                ? const Color(0xFFcc0000)
                : const Color(0xFF004400));
        break;
      case TT.SOFA:
        final gS = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gS]);
        fillRect(canvas, sx + 1, sy + 3, size - 2, size - 5, CLR.sofa);
        fillRect(canvas, sx + 1, sy + 3, size - 2, 3, const Color(0xFF9a7030));
        break;
      case TT.KITCHEN:
        final gK = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gK]);
        fillRect(canvas, sx + 1, sy + 1, size - 2, size - 2, CLR.kitchen);
        fillRect(canvas, sx + 3, sy + 3, 4, 3, const Color(0xFF8a8a8a));
        fillRect(canvas, sx + size - 7, sy + 3, 4, 3, const Color(0xFF8a8a8a));
        break;
      case TT.DESK:
        final gD = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gD]);
        fillRect(canvas, sx + 1, sy + 2, size - 2, size - 4, CLR.desk);
        fillRect(canvas, sx + 3, sy + 3, size - 6, size - 8,
            const Color(0x4D64A0FF));
        break;
      case TT.DINING:
        final gDn = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gDn]);
        fillRect(canvas, sx + 2, sy + 2, size - 4, size - 4, CLR.dining);
        break;
      case TT.TV:
        final gT = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gT]);
        fillRect(canvas, sx + 1, sy + 2, size - 2, size - 4, CLR.tv);
        fillRect(canvas, sx + 2, sy + 3, size - 4, size - 6,
            const Color(0x8C2850DC));
        break;
      case TT.STAIRS:
        final gSt = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gSt]);
        for (int s = 0; s < 4; s++) {
          fillRect(canvas, sx + s * 3.0, sy + s * 3.0, size - s * 6.0, 2,
              const Color(0x0D000000).withOpacity(0.08 + s * 0.05));
        }
        break;
      case TT.ELEVATOR:
        final gEl = bldGroup(tx, ty);
        fillRect(canvas, sx, sy, size, size, CLR.bfloor[gEl]);
        fillRect(canvas, sx + 2, sy + 2, size - 4, size - 4,
            const Color(0xFF909090));
        fillRect(canvas, sx + size / 2 - 1, sy + 4, 2, size - 8,
            const Color(0xFFc0c0c0));
        fillRect(canvas, sx + 4, sy + size / 2 - 1, size - 8, 2,
            const Color(0xFFc0c0c0));
        break;
      case TT.MAPITEM:
        final mp = (math.sin(now / 300.0) + 1) / 2;
        fillRect(canvas, sx, sy, size, size,
            CLR.mapItem.withOpacity(0.15 + mp * 0.15));
        drawText(canvas, 'M', sx + size / 2, sy + 1, CLR.mapItem,
            size - 4, bold: true, align: 'center');
        break;
      default:
        fillRect(canvas, sx, sy, size, size, CLR.bg);
    }
  }

  // ── Interior tile drawing ─────────────────────────────────────────────────
  void _drawTileInterior(Canvas canvas, int tile, double sx, double sy) {
    final size = TSI;
    _paintTile(canvas, tile, 0, 0, sx, sy, size.toDouble());
  }

  // ── Building facades ──────────────────────────────────────────────────────
  void _renderBuildings(Canvas canvas, World w,
      ({double x, double y}) cam, double cw, double ch) {
    for (final bld in w.buildings) {
      final sx0 = (bld.x0 - cam.x) * TS;
      final sy0 = (bld.y0 - cam.y) * TS;
      final sx1 = (bld.x1 - cam.x) * TS;
      final sy1 = (bld.y1 - cam.y) * TS;
      final sw  = sx1 - sx0, sh = sy1 - sy0;
      if (sx1 < -TS || sx0 > cw + TS || sy1 < -TS * 3 || sy0 > ch + TS) continue;
      final g = bld.id & 3;
      if (bld.type == 'house') {
        _drawHouseFacade(canvas, bld, sx0, sy0, sx1, sy1, sw, sh, g);
      } else {
        _drawBuildingFacade(canvas, bld, sx0, sy0, sx1, sy1, sw, sh, g);
      }
      // Red flashing indicator if indoor zombie present
      final hasIndoorZ = zombies.any((z) =>
          z.alive && w.getBuildingIdAt(z.x.floor(), z.y.floor()) == bld.id);
      if (hasIndoorZ) {
        final flash = (now ~/ 400) % 2 == 0;
        if (flash) {
          drawText(canvas, '?', sx0 + sw / 2, sy0 + 2,
              const Color(0xFFff2222), 12, bold: true, align: 'center');
        }
      }
    }
  }

  void _drawHouseFacade(Canvas canvas, BuildingData bld,
      double sx0, double sy0, double sx1, double sy1,
      double sw, double sh, int g) {
    final wc2 = CLR.facadeWall[g];
    final rc  = CLR.facadeRoof[g];

    // Roof
    fillRect(canvas, sx0, sy0, sw, sh, rc);
    // Roof grid
    for (double rx = sx0 + TS; rx < sx1; rx += TS)
      fillRect(canvas, rx, sy0, 1, sh, const Color(0x12000000));
    for (double ry = sy0 + TS; ry < sy1; ry += TS)
      fillRect(canvas, sx0, ry, sw, 1, const Color(0x12000000));
    fillRect(canvas, sx0, sy0, sw, 3, const Color(0x33000000));
    // Ridge
    fillRect(canvas, sx0 + sw * 0.15, sy0 + 2, sw * 0.7, 2,
        const Color(0x26000000));

    // South facade
    const facH = TS * 1.85;
    fillRect(canvas, sx0, sy1 - TS * 0.15, sw, facH, wc2);
    fillRect(canvas, sx0, sy1 - TS * 0.15, sw, 5, const Color(0x52000000));

    // Brick texture
    if (g == 2) {
      for (double ry = sy1 + 3; ry < sy1 + facH; ry += 7) {
        final off = (((ry - sy1) / 7).floor() % 2) * 10.0;
        for (double rx = sx0 + off - 10; rx < sx1 + 10; rx += 20)
          fillRect(canvas, rx, ry, 1, 6, const Color(0x14000000));
        fillRect(canvas, sx0, ry + 6, sw, 1, const Color(0x14000000));
      }
    }

    // Windows
    final nW = math.max(1, (sw / (TS * 4)).floor());
    final wW = TS * 1.25, wH = TS * 0.85;
    final wSpacing = sw / (nW + 1);
    final midX = sx0 + sw / 2;
    final wY = sy1 + facH * 0.18;
    for (int i = 1; i <= nW; i++) {
      final wx = sx0 + i * wSpacing - wW / 2;
      if (wx + wW > midX - TS * 0.9 && wx < midX + TS * 0.9) continue;
      _drawFacadeWindow(canvas, wx, wY, wW, wH, g);
    }

    // Door
    final dW = TS * 1.5, dH = TS * 1.75;
    final dX = midX - dW / 2, dY = sy1 + facH * 0.08;
    _drawFacadeDoor(canvas, dX, dY, dW, dH);
    fillRect(canvas, dX - 3, dY + dH, dW + 6, 4, const Color(0xFFc0b8a8));
    fillRect(canvas, dX - 6, dY + dH + 4, dW + 12, 4, const Color(0xFFa8a098));
  }

  void _drawBuildingFacade(Canvas canvas, BuildingData bld,
      double sx0, double sy0, double sx1, double sy1,
      double sw, double sh, int g) {
    final wc2 = CLR.facadeWall[g];
    final rc  = CLR.facadeRoof[g];

    // Flat roof with HVAC units
    fillRect(canvas, sx0, sy0, sw, sh, rc);
    fillRect(canvas, sx0, sy0, sw, 2, const Color(0x33000000));
    // AC units
    for (double ux = sx0 + TS; ux < sx1 - TS; ux += TS * 4) {
      fillRect(canvas, ux, sy0 + 3, TS * 1.5, TS * 0.8, const Color(0xFFaaaaaa));
      fillRect(canvas, ux + 2, sy0 + 5, TS * 1.5 - 4, TS * 0.8 - 4,
          const Color(0xFF888888));
    }

    // Facade with window grid
    const facH = TS * 2.2;
    fillRect(canvas, sx0, sy1 - TS * 0.1, sw, facH, wc2);
    fillRect(canvas, sx0, sy1 - TS * 0.1, sw, 4, const Color(0x52000000));

    // Window grid
    final wW = TS * 1.1, wH = TS * 0.9, wSpaceX = sw / 5.0;
    final wY = sy1 + facH * 0.15;
    for (int i = 1; i <= 4; i++) {
      final wx = sx0 + i * wSpaceX - wW / 2;
      _drawFacadeWindow(canvas, wx, wY, wW, wH, g);
    }

    // Doors
    final d1X = sx0 + sw * 0.28, d2X = sx0 + sw * 0.62;
    const dW = TS * 1.8, dH = TS * 2.0;
    final dY = sy1 + facH * 0.05;
    _drawFacadeDoor(canvas, d1X, dY, dW, dH);
    _drawFacadeDoor(canvas, d2X, dY, dW, dH);

    // Building number
    drawText(canvas, '#${bld.id + 1}', sx0 + sw / 2, sy0 + sh * 0.3,
        const Color(0x66000000), 10, bold: true, align: 'center');
  }

  void _drawFacadeWindow(Canvas canvas, double x, double y,
      double w, double h, int g) {
    fillRect(canvas, x, y, w, h, CLR.windowBg);
    fillRect(canvas, x + 2, y + 2, w - 4, h - 4, CLR.window);
    fillRect(canvas, x + 2, y + 2, w - 6, 2, CLR.windowShine);
    // Cross bar
    fillRect(canvas, x + w / 2 - 0.5, y, 1, h, const Color(0x33000000));
    fillRect(canvas, x, y + h / 2 - 0.5, w, 1, const Color(0x33000000));
  }

  void _drawFacadeDoor(Canvas canvas, double x, double y, double w, double h) {
    fillRect(canvas, x, y, w, h, CLR.door);
    fillRect(canvas, x + 2, y + 2, w - 4, h - 2, CLR.doorPanel);
    fillRect(canvas, x + w - 7, y + h / 2 - 2, 3, 3, const Color(0xFFd4a030));
  }

  // ── Exit indicator ────────────────────────────────────────────────────────
  void _renderExitIndicator(Canvas canvas, World w,
      ({double x, double y}) cam, double cw, double ch) {
    final et = w.exitTile;
    if (et == null) return;
    final pulse = (math.sin(now / 300.0) + 1) / 2;
    final ex = (et.x - cam.x) * TS, ey = (et.y - cam.y) * TS;
    if (ex > -80 && ex < cw + 80 && ey > -80 && ey < ch + 80) {
      canvas.drawRect(
        Rect.fromLTWH(ex - ROAD_HALF * TS - 4, ey - 4,
            ROAD_HALF * 2 * TS + 8, WALL_T * TS + 8),
        Paint()
          ..color = CLR.exitGlow.withOpacity(0.3 + pulse * 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    final margin = 70.0;
    if (ex < margin || ex > cw - margin || ey < margin || ey > ch - margin) {
      final dcx = et.x - (cam.x + cw / TS / 2);
      final dcy = et.y - (cam.y + ch / TS / 2);
      final angle = math.atan2(dcy, dcx);
      final ax = (cw / 2 + math.cos(angle) * 220)
          .clamp(margin, cw - margin);
      final ay = (ch / 2 + math.sin(angle) * 180)
          .clamp(margin, ch - margin);
      drawText(canvas, '⬤ SAÍDA', ax, ay - 18,
          CLR.exitGlow.withOpacity(0.6 + pulse * 0.4), 13,
          bold: true, align: 'center');
      // Arrow
      canvas.save();
      canvas.translate(ax, ay);
      canvas.rotate(angle);
      canvas.drawRect(Rect.fromLTWH(-10, -5, 20, 10),
          Paint()..color = CLR.exitGlow.withOpacity(0.6 + pulse * 0.4));
      canvas.restore();
    }
  }

  // ── Minimap ───────────────────────────────────────────────────────────────
  void _renderMinimap(Canvas canvas, World w,
      ({double x, double y}) cam, double cw, double ch) {
    const MM = 152.0;
    const PAD = 12.0;
    final mx = cw - MM - PAD, my = ch - MM - PAD;

    fillRect(canvas, mx - 2, my - 2, MM + 4, MM + 4,
        const Color(0xC7000000));
    canvas.drawRect(Rect.fromLTWH(mx - 2, my - 2, MM + 4, MM + 4),
        Paint()
          ..color = const Color(0xFF2a2a2a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // Cached picture
    if (w.mmCache != null) {
      canvas.save();
      canvas.translate(mx, my);
      canvas.scale(MM / 192.0, MM / 192.0);
      canvas.drawPicture(w.mmCache!);
      canvas.restore();
    }

    // Viewport rect
    canvas.drawRect(
      Rect.fromLTWH(
        mx + (cam.x / w.wt) * MM,
        my + (cam.y / w.wt) * MM,
        (cw / TS / w.wt) * MM,
        (ch / TS / w.wt) * MM,
      ),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // NPCs
    final npcPaint = Paint()..color = const Color(0xFF4488ff);
    for (final npc in npcs) {
      if (!npc.alive) continue;
      canvas.drawRect(
        Rect.fromLTWH(mx + (npc.x / w.wt) * MM - 1, my + (npc.y / w.wt) * MM - 1, 2, 2),
        npcPaint,
      );
    }
    // Zombies
    for (final z in zombies) {
      if (!z.alive) continue;
      final zCol = z.state == 'chase'
          ? CLR.alertFg[2]
          : (z.state == 'alert' ? CLR.alertFg[1] : const Color(0xFF30903a));
      canvas.drawRect(
        Rect.fromLTWH(mx + (z.x / w.wt) * MM - 1, my + (z.y / w.wt) * MM - 1, 2, 2),
        Paint()..color = zCol,
      );
    }
    // Exit
    final et = w.exitTile;
    if (et != null) {
      final p2 = (math.sin(now / 300.0) + 1) / 2;
      canvas.drawRect(
        Rect.fromLTWH(mx + (et.x / w.wt) * MM - 2, my + (et.y / w.wt) * MM - 2, 4, 4),
        Paint()..color = CLR.exitGlow.withOpacity(0.7 + p2 * 0.3),
      );
    }
    // Player
    final p = player!;
    canvas.drawRect(
      Rect.fromLTWH(mx + (p.x / w.wt) * MM - 2, my + (p.y / w.wt) * MM - 2, 4, 4),
      Paint()..color = CLR.hero,
    );

    drawText(canvas, 'MAPA', mx, my - 12, const Color(0xFF555555), 8);
  }

  void _renderMinimapLocked(Canvas canvas, double cw, double ch) {
    const MM = 152.0, PAD = 12.0;
    final mx = cw - MM - PAD, my = ch - MM - PAD;
    fillRect(canvas, mx - 2, my - 2, MM + 4, MM + 4, const Color(0x99000000));
    fillRect(canvas, mx, my, MM, MM, const Color(0xFF1a1a1a));
    drawText(canvas, '[ MAPA BLOQUEADO ]', mx + MM / 2, my + MM / 2 - 16,
        const Color(0xFF2a2a2a), 12, bold: true, align: 'center');
    drawText(canvas, 'Colete item [M]', mx + MM / 2, my + MM / 2 + 6,
        const Color(0xFF222222), 10, align: 'center');
    drawText(canvas, 'para revelar', mx + MM / 2, my + MM / 2 + 20,
        const Color(0xFF222222), 10, align: 'center');
  }

  // ── HUD ───────────────────────────────────────────────────────────────────
  void _renderHUD(Canvas canvas, Size size) {
    final p = player;
    if (p == null) return;
    final cw = size.width, ch = size.height;

    // Top-left: hearts + lives
    final tlBg = Paint()..color = const Color(0x85000000);
    canvas.drawRect(Rect.fromLTWH(14, 14, 110, 52), tlBg);
    for (int i = 0; i < p.maxHearts; i++) {
      drawText(canvas, '♥', 22 + i * 24.0, 20,
          i < p.hearts ? CLR.heartFull : CLR.heartEmpty, 22, bold: true);
    }
    drawText(canvas, '💀 × ${p.lives}', 22, 46, const Color(0xFF666666), 14);

    // Top-centre: score + counters
    // Os zumbis do interior são gêmeos dos do mundo — contar só o mundo
    // evita contagem dupla enquanto o jogador está dentro de um prédio.
    final aliveZ   = zombies.where((z) => z.alive).length;
    final aliveNpc = npcs.where((n) => n.alive).length;
    final tcW = 190.0;
    final tcX = cw / 2 - tcW / 2;
    canvas.drawRect(Rect.fromLTWH(tcX, 14, tcW, 70), tlBg);
    drawText(canvas, p.score.toString().replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.'),
        cw / 2, 18, Colors.white, 26, bold: false, align: 'center');
    drawText(canvas, '🧟 $aliveZ', cw / 2 - 40, 50,
        const Color(0xFF30903a), 12, align: 'center');
    drawText(canvas, '👤 $aliveNpc', cw / 2 + 10, 50,
        const Color(0xFF3366bb), 12, align: 'center');
    drawText(canvas, 'FASE $phase  MAPA ${hasMap ? "🗺" : "?"}',
        cw / 2, 66, const Color(0xFF333333), 10, align: 'center');

    // Top-right: weapon + ammo
    canvas.drawRect(Rect.fromLTWH(cw - 120, 14, 106, 66), tlBg);
    drawText(canvas, p.weapon.toUpperCase(), cw - 67, 20,
        const Color(0xFFaaaaaa), 15, bold: false, align: 'center');
    final ammoStr = p.weapon == 'knife' ? '∞' : '${p.ammo[p.weapon] ?? 0}';
    drawText(canvas, ammoStr, cw - 67, 40,
        const Color(0xFF3a3a3a), 12, align: 'center');
    drawText(canvas, '1-Faca  2-Rev  3-Shot  4-Rifle',
        cw - 67, 58, const Color(0xFF242424), 8, align: 'center');

    // Alert box
    final al = p.alertLevel;
    final alertBg2 = Paint()..color = CLR.alertBg[al];
    canvas.drawRect(Rect.fromLTWH(cw - 120, 94, 106, 36), alertBg2);
    canvas.drawRect(Rect.fromLTWH(cw - 120, 94, 106, 36),
        Paint()
          ..color = CLR.alertBdr[al]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    drawText(canvas, CLR.alertLbl[al], cw - 67, 100,
        CLR.alertFg[al], 13, bold: true, align: 'center');

    // Bottom controls hint
    drawText(canvas,
        'WASD·Mover  SPACE·Atacar  Shift·Correr  ↑·Entrar  M·Som',
        cw / 2, ch - 14, const Color(0xFF1e1e1e), 10, align: 'center');
  }

  // ── Popup ─────────────────────────────────────────────────────────────────
  void _renderPopup(Canvas canvas, Player p, ({double x, double y}) cam,
      bool isInterior, Size size) {
    if (popupTimer <= 0) return;
    final alpha = math.min(1.0, popupTimer / 350.0);
    double px2, py2;
    if (isInterior) {
      final lay = insideBuilding!.interior.getLayout();
      final offX = ((size.width  - lay.W * TSI) / 2).floorToDouble();
      final offY = ((size.height - lay.H * TSI) / 2).floorToDouble();
      px2 = offX + p.x * TSI + TSI / 2;
      py2 = offY + p.y * TSI - 20;
    } else {
      px2 = (p.x - cam.x) * TS + TS / 2;
      py2 = (p.y - cam.y) * TS - 20;
    }
    drawText(canvas, popupMsg, px2, py2,
        Colors.white.withOpacity(alpha), 20, bold: true, align: 'center');
  }

  // ── Title screen ──────────────────────────────────────────────────────────
  void _drawTitle(Canvas canvas, Size size) {
    final W = size.width, H = size.height;

    fillRect(canvas, 0, 0, W, H, const Color(0xFF1a3a1a));

    // Grid
    final gridPaint = Paint()
      ..color = const Color(0x0F50A050)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (double x = 0; x < W; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, H), gridPaint);
    }
    for (double y = 0; y < H; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(W, y), gridPaint);
    }

    drawText(canvas, 'ZOMBIE', W / 2, H * 0.20, CLR.hero, 88,
        bold: true, align: 'center');
    drawText(canvas, '2600', W / 2, H * 0.38, const Color(0xFF50b450), 88,
        bold: true, align: 'center');

    drawText(canvas, '— SOBREVIVA, COLETE O MAPA E ESCAPE DA CIDADE —',
        W / 2, H * 0.55, const Color(0x4DFFFFFF), 15, align: 'center');

    if ((now ~/ 550) % 2 == 0) {
      drawText(canvas, '[ ESPAÇO ] PARA COMEÇAR', W / 2, H * 0.65,
          const Color(0x99FFFFFF), 15, align: 'center');
    }

    // Sprites
    drawPixelSprite(canvas, getSpriteMatrix(1),
        W / 2 - 120, H * 0.28, PP + 1, CLR.hero, null);
    drawPixelSprite(canvas, getSpriteMatrix(0),
        W / 2 + 80, H * 0.28, PP + 1, const Color(0xFF50b450), CLR.zombieEye);

    drawText(canvas,
        'WASD · Mover   SPACE · Atacar   1-4 · Arma   Shift · Correr   ↑ Porta',
        W / 2, H - 40, const Color(0x2EFFFFFF), 12, align: 'center');
    drawText(canvas,
        'Colete [M] para revelar mapa  ·  Saída verde = próxima fase',
        W / 2, H - 22, const Color(0x2EFFFFFF), 12, align: 'center');
  }

  // ── Game over screen ──────────────────────────────────────────────────────
  void _drawGameOver(Canvas canvas, Size size) {
    final W = size.width, H = size.height;
    fillRect(canvas, 0, 0, W, H, const Color(0xB8000000));
    drawText(canvas, 'VOCÊ MORREU', W / 2, H / 2 - 40,
        CLR.alertFg[2], 68, bold: true, align: 'center');
    drawText(canvas, 'Pontuação: ${player?.score ?? 0}',
        W / 2, H / 2 + 20, const Color(0xFF888888), 22, align: 'center');
    if ((now ~/ 550) % 2 == 0) {
      drawText(canvas, '[ ESPAÇO ] menu', W / 2, H / 2 + 60,
          const Color(0xFF444444), 14, align: 'center');
    }
  }

  // ── Victory / comic panels ────────────────────────────────────────────────
  void _drawVictory(Canvas canvas, Size size) {
    final W = size.width, H = size.height;
    fillRect(canvas, 0, 0, W, H, const Color(0xFF1a1a10));

    // Title
    drawText(canvas, 'ESCAPOU!', W / 2, 30, CLR.exitGlow, 40,
        bold: true, align: 'center');
    drawText(canvas, 'Fase $phase  ·  ${player?.score ?? 0} pts',
        W / 2, 78, const Color(0xFF888888), 18, align: 'center');

    // Build panel list
    final panels = <({String title, String body, Color accent, bool hasHero, bool hasZombie})>[];

    panels.add((
      title: 'A FUGA',
      body: 'O sobrevivente escapou\npela saída da cidade.',
      accent: CLR.exitGlow,
      hasHero: true,
      hasZombie: false,
    ));
    if (stats.killCount > 0) {
      panels.add((
        title: 'ELIMINADOS',
        body: '${stats.killCount} zumbis abatidos\n+${stats.killCount * GAME.scorePerKill} pts',
        accent: CLR.hero,
        hasHero: true,
        hasZombie: true,
      ));
    }
    if (stats.sawInfection) {
      panels.add((
        title: 'INFECTADO!',
        body: 'Um sobrevivente foi\ntransformado em zumbi.',
        accent: CLR.alertFg[1],
        hasHero: false,
        hasZombie: true,
      ));
    }
    if (stats.hadHorde) {
      panels.add((
        title: 'A HORDA',
        body: 'Perseguido por\n3+ zumbis!',
        accent: CLR.alertFg[2],
        hasHero: true,
        hasZombie: true,
      ));
    }

    final count  = math.min(panels.length, 4);
    final panW   = (W - 80) / count - 16;
    const panH   = 220.0;
    final startX = 40.0;
    final panY   = H / 2 - panH / 2 + 20;

    for (int i = 0; i < count; i++) {
      final pan = panels[i];
      final px2 = startX + i * (panW + 16);
      _drawComicPanel(canvas, px2, panY, panW, panH, pan, i);
    }

    final nextWC = (phase + 1) % 2 == 0 && worldWC < GAME.maxWorldWC
        ? worldWC + 1
        : worldWC;
    drawText(canvas,
        'Próxima fase: ${GAME.zombiesForPhase(phase + 1)} zumbis · '
        '${GAME.npcsForPhase(phase + 1)} sobreviventes · mapa $nextWC×$nextWC',
        W / 2, H - 50, const Color(0xFF444444), 12, align: 'center');

    if ((now ~/ 550) % 2 == 0) {
      drawText(canvas, '[ ESPAÇO ] Próxima Fase', W / 2, H - 28,
          const Color(0xFF888866), 14, align: 'center');
    }
  }

  void _drawComicPanel(
    Canvas canvas,
    double x, double y, double w, double h,
    ({String title, String body, Color accent, bool hasHero, bool hasZombie}) pan,
    int idx,
  ) {
    final tilt = (idx % 2 == 0 ? 1.0 : -1.0) * 0.02;
    canvas.save();
    canvas.translate(x + w / 2, y + h / 2);
    canvas.rotate(tilt);
    canvas.translate(-(x + w / 2), -(y + h / 2));

    // Panel bg
    fillRect(canvas, x + 3, y + 3, w, h, const Color(0xFF1a1a1a));
    fillRect(canvas, x, y, w, h, const Color(0xFFe8e4d8));
    canvas.drawRect(Rect.fromLTWH(x, y, w, h),
        Paint()
          ..color = const Color(0xFF1a1a1a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);

    // Halftone dots
    for (double dy = 6; dy < h - 6; dy += 6) {
      for (double dx = 6; dx < w - 6; dx += 6) {
        fillCircle(canvas, x + dx, y + dy, 1.2,
            const Color(0xFF000000).withOpacity(0.04));
      }
    }

    // Title strip
    fillRect(canvas, x, y, w, 28, pan.accent.withOpacity(0.9));
    drawText(canvas, pan.title, x + w / 2, y + 5,
        const Color(0xFFFFFFFF), 14, bold: true, align: 'center');

    // Scene (pixel art mini sprites)
    final sceneY = y + 35;
    final sceneH = h - 80.0;
    if (pan.hasHero) {
      drawPixelSprite(canvas, getSpriteMatrix(1),
          x + w * 0.15, sceneY + sceneH / 2 - 12, PP + 1, CLR.hero, null);
    }
    if (pan.hasZombie) {
      drawPixelSprite(canvas, getSpriteMatrix(3),
          x + w * 0.55, sceneY + sceneH / 2 - 12, PP + 1,
          CLR.zombie, CLR.zombieEye);
    }

    // Body text
    final lines = pan.body.split('\n');
    for (int li = 0; li < lines.length; li++) {
      drawText(canvas, lines[li],
          x + w / 2, y + h - 46 + li * 16.0,
          const Color(0xFF1a1a1a), 10, align: 'center');
    }

    canvas.restore();
  }
}

// ─── Flutter GameWidget ────────────────────────────────────────────────────────
class GameWidget extends StatefulWidget {
  const GameWidget({super.key});
  @override
  State<GameWidget> createState() => _GameWidgetState();
}

class _GameWidgetState extends State<GameWidget>
    with TickerProviderStateMixin {
  late Ticker _ticker;
  final Game _game = Game();
  Duration _lastElapsed = Duration.zero;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = _lastElapsed == Duration.zero
          ? 0.016
          : (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
      _lastElapsed = elapsed;
      _game.update(dt.clamp(0.001, 0.05));
      if (mounted) setState(() {});
    });
    _ticker.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKey(RawKeyEvent event) {
    final down = event is RawKeyDownEvent;
    final key  = event.logicalKey;
    final g    = _game;
    final inp  = g.input;

    if (down) {
      if (key == LogicalKeyboardKey.space) {
        if (g.state == GameState.title)    { g.startGame(false); return; }
        if (g.state == GameState.gameover) { g.state = GameState.title; return; }
        if (g.state == GameState.victory)  { g.nextPhase(); return; }
        inp.attack = true;
      }
      if (g.state == GameState.playing) {
        if (key == LogicalKeyboardKey.digit1) _switchWeapon('knife');
        if (key == LogicalKeyboardKey.digit2) _switchWeapon('revolver');
        if (key == LogicalKeyboardKey.digit3) _switchWeapon('shotgun');
        if (key == LogicalKeyboardKey.digit4) _switchWeapon('rifle');
      }
    }

    void set(bool v) {
      if (key == LogicalKeyboardKey.arrowLeft  || key == LogicalKeyboardKey.keyA) inp.left  = v;
      if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD) inp.right = v;
      if (key == LogicalKeyboardKey.arrowUp    || key == LogicalKeyboardKey.keyW) inp.up    = v;
      if (key == LogicalKeyboardKey.arrowDown  || key == LogicalKeyboardKey.keyS) inp.down  = v;
      if (key == LogicalKeyboardKey.shiftLeft  || key == LogicalKeyboardKey.shiftRight) inp.sprint = v;
      if (key == LogicalKeyboardKey.keyE) inp.interact = v;
      if (key == LogicalKeyboardKey.space && g.state == GameState.playing) inp.attack = v;
    }
    set(down);
  }

  void _switchWeapon(String w) {
    final p = _game.player;
    if (p != null && p.weapons.contains(w)) {
      p.weapon = w;
      _game._popup(w.toUpperCase());
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKey,
      child: GestureDetector(
        onTapDown: (_) => _focusNode.requestFocus(),
        child: Container(
          color: const Color(0xFF060d06),
          child: CustomPaint(
            painter: _GamePainter(_game),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _GamePainter extends CustomPainter {
  final Game game;
  _GamePainter(this.game);

  @override
  void paint(Canvas canvas, Size size) {
    game.render(canvas, size);
  }

  @override
  bool shouldRepaint(_GamePainter old) => true;
}
