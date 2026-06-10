import 'dart:math' as math;
import 'dart:ui' hide TextStyle;
import 'config.dart';
import 'sprites.dart';
import 'world.dart';
import 'interior.dart';

// ─── Abstract world interface used by Entity ─────────────────────────────────
abstract class IWorld {
  bool isWalkable(int x, int y);
  int get(int x, int y);
  bool lineOfSight(double ax, double ay, double bx, double by);
}

class _WorldAdapter implements IWorld {
  final World w;
  _WorldAdapter(this.w);
  @override bool isWalkable(int x, int y) => w.isWalkable(x, y);
  @override int  get(int x, int y)        => w.get(x, y);
  @override bool lineOfSight(double ax, double ay, double bx, double by) =>
      w.lineOfSight(ax, ay, bx, by);
}

class _InteriorAdapter implements IWorld {
  final Interior i;
  _InteriorAdapter(this.i);
  @override bool isWalkable(int x, int y) => i.isWalkable(x.toDouble(), y.toDouble());
  @override int  get(int x, int y)        => i.get(x.toDouble(), y.toDouble());
  @override bool lineOfSight(double ax, double ay, double bx, double by) =>
      i.lineOfSight(ax, ay, bx, by);
}

IWorld worldAdapter(World w)     => _WorldAdapter(w);
IWorld interiorAdapter(Interior i) => _InteriorAdapter(i);

// ─── Base Entity ─────────────────────────────────────────────────────────────
abstract class Entity {
  double x, y, vx = 0, vy = 0;
  int dir = 0; // 0=down 1=right 2=up 3=left
  bool alive = true;

  Entity(this.x, this.y);

  bool _canMove(double nx, double ny, IWorld world, [double hw = 0.36]) =>
      world.isWalkable((nx - hw).floor(), (ny - hw).floor()) &&
      world.isWalkable((nx + hw).floor(), (ny - hw).floor()) &&
      world.isWalkable((nx - hw).floor(), (ny + hw).floor()) &&
      world.isWalkable((nx + hw).floor(), (ny + hw).floor());

  void move(double dt, IWorld world) {
    final nx = x + vx * dt, ny = y + vy * dt;
    if (_canMove(nx, y, world)) x = nx;
    if (_canMove(x, ny, world)) y = ny;
    if (vx.abs() > vy.abs()) {
      dir = vx > 0 ? 1 : 3;
    } else if (vy.abs() > 0.01) {
      dir = vy > 0 ? 0 : 2;
    }
  }

  double distTo(Entity other) =>
      math.sqrt((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y));
  double distToXY(double ox, double oy) =>
      math.sqrt((x - ox) * (x - ox) + (y - oy) * (y - oy));

  bool onScreen(({double x, double y}) cam, double cw, double ch) {
    final sx = (x - cam.x) * TS, sy = (y - cam.y) * TS;
    return sx > -32 && sx < cw + 32 && sy > -32 && sy < ch + 32;
  }
}

// ─── Player ───────────────────────────────────────────────────────────────────
class Player extends Entity {
  int hearts = 3, maxHearts = 3, lives = 3, score = 0;
  String weapon = 'knife';
  final Set<String> weapons = {'knife'};
  final Map<String, int> ammo = {'revolver': 0, 'shotgun': 0, 'rifle': 0};
  int alertLevel = 0;
  double soundRadius = 0;
  double soundCd = 0;
  bool isIndoor = false;
  double invincTimer = 0;
  bool attacking = false;
  double atkTimer = 0;
  bool atkJustFired = false;

  Player(super.x, super.y);

  void update(double dt, InputState input, IWorld world, int now) {
    final ms = dt * 1000;
    final speed = GAME.playerSpeed * (input.sprint ? GAME.sprintMult : 1.0);
    vx = 0; vy = 0;
    if (input.left)  vx -= speed;
    if (input.right) vx += speed;
    if (input.up)    vy -= speed;
    if (input.down)  vy += speed;
    if (vx != 0 && vy != 0) { vx *= 0.707; vy *= 0.707; }
    move(dt, world);

    final tx = x.floor(), ty = y.floor();
    final tileHere = world.get(tx, ty);
    isIndoor = tileHere == TT.BFLOOR || tileHere == TT.DOOR;

    if (vx != 0 || vy != 0) {
      soundCd -= ms;
      if (soundCd <= 0) {
        soundRadius = isIndoor ? GAME.zombieHearIndoor : GAME.zombieHear;
        soundCd = GAME.soundWalkCd.toDouble();
      }
    } else {
      soundRadius = math.max(0, soundRadius - 28 * dt);
    }

    atkJustFired = false;
    if (input.attack && !attacking) {
      attacking    = true;
      atkTimer     = 360;
      atkJustFired = true;
    }
    if (attacking) { atkTimer -= ms; if (atkTimer <= 0) attacking = false; }
    if (invincTimer > 0) invincTimer -= ms;
  }

  bool takeDamage() {
    if (invincTimer > 0) return false;
    invincTimer = GAME.invincDuration.toDouble();
    hearts--;
    if (hearts <= 0) {
      lives--;
      hearts = maxHearts;
      if (lives <= 0) alive = false;
    }
    return true;
  }

  void heal(int n) => hearts = math.min(maxHearts, hearts + n);

  void gainScore(int n) {
    final prev = score;
    score += n;
    if ((score ~/ GAME.lifeEvery) > (prev ~/ GAME.lifeEvery)) lives++;
  }

  void draw(Canvas canvas, ({double x, double y}) cam, double cw, double ch, int now) {
    if (!onScreen(cam, cw, ch)) return;
    final px = (x - cam.x) * TS, py = (y - cam.y) * TS;
    final pw = 7 * PP, ph = 6 * PP;
    final dx = px + (TS - pw) / 2, dy = py + (TS - ph) / 2;

    if (invincTimer > 0 && ((invincTimer / 130).floor() % 2 == 0)) return;

    // Shadow
    fillEllipse(canvas, px + TS / 2, py + TS - 2, TS / 3, 3,
        const Color(0x38000000));
    drawPixelSprite(canvas, getSpriteMatrix(dir), dx, dy, PP, CLR.hero, null);

    if (attacking) {
      final alpha = (atkTimer / 360) * 0.5;
      canvas.drawCircle(
        Offset(px + TS / 2, py + TS / 2),
        GAME.playerAttackRange * TS,
        Paint()
          ..color = CLR.hero.withOpacity(alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  // Draw in interior view (TSI scale)
  void drawInterior(Canvas canvas, ({double x, double y}) offset) {
    final px = offset.x + x * TSI, py = offset.y + y * TSI;
    final pw = 7 * PPI, ph = 6 * PPI;
    final dx = px + (TSI - pw) / 2, dy = py + (TSI - ph) / 2;
    if (invincTimer > 0 && ((invincTimer / 130).floor() % 2 == 0)) return;
    fillEllipse(canvas, px + TSI / 2, py + TSI - 2, TSI / 3, 4,
        const Color(0x38000000));
    drawPixelSprite(canvas, getSpriteMatrix(dir), dx, dy, PPI, CLR.hero, null);
  }
}

// ─── Input state ──────────────────────────────────────────────────────────────
class InputState {
  bool left = false, right = false, up = false, down = false;
  bool attack = false, sprint = false, interact = false;
}

// ─── Zombie ───────────────────────────────────────────────────────────────────
class Zombie extends Entity {
  String state = 'patrol'; // 'patrol' | 'alert' | 'chase'
  int hp       = GAME.zombieHp;
  double atkCd = 0;
  double patrolTimer = 0;
  ({double x, double y}) patrolTarget;
  double alertTimer = 0;
  ({double x, double y})? alertTarget;
  ({double x, double y})? lastSeen;
  double chaseTimer = 0;
  double stuckCk = 0, stuckTimer = 0;
  double lastPosX, lastPosY;
  double doorBreakTimer = 0;
  bool breakoutMode;
  ({double x, double y})? nearestDoor;

  Zombie(super.x, super.y, {this.breakoutMode = false})
      : patrolTarget = (x: x, y: y),
        lastPosX     = x,
        lastPosY     = y;

  void update(double dt, Player player, IWorld world,
      [List<NPC>? npcs, int now = 0]) {
    final ms = dt * 1000;

    // Find closest target (player or NPC)
    Entity target = player;
    double targetDist = distTo(player);
    if (npcs != null) {
      for (final npc in npcs) {
        if (!npc.alive || npc.infected) continue;
        final d = distTo(npc);
        if (d < targetDist) { targetDist = d; target = npc; }
      }
    }

    // Breakout mode (indoor zombie trying to escape)
    if (breakoutMode) {
      _doBreakout(dt, world);
      return;
    }

    // Sound detection
    if (state != 'chase' && player.soundRadius > 0 &&
        distTo(player) < player.soundRadius) {
      _gotoAlert((x: player.x, y: player.y), GAME.zombieAlertDecay.toDouble());
    }

    final dist = targetDist;
    final los  = dist < GAME.zombieVision + 2 &&
        world.lineOfSight(this.x, this.y, target.x, target.y);

    // State machine
    if (los) {
      _gotoChase(target);
    } else if (state == 'chase') {
      chaseTimer -= ms;
      if (chaseTimer <= 0) { state = 'alert'; alertTimer = GAME.zombieAlertDecay.toDouble(); }
    } else if (state == 'alert') {
      alertTimer -= ms;
      if (alertTimer <= 0) state = 'patrol';
    }

    // Movement
    if (state == 'chase')       _doChase(dt, world);
    else if (state == 'alert')  _doAlert(dt, world);
    else                        _doPatrol(dt, world);

    // Attack
    atkCd -= ms;
    if (atkCd <= 0 && dist < 1.1 && los) {
      atkCd = GAME.zombieAttackCd.toDouble();
      if (target is Player) target.takeDamage();
      if (target is NPC && !target.infected) {
        target.infected       = true;
        target.infectionTimer = GAME.infectionDelay.toDouble();
      }
    }

    // Stuck detection
    stuckCk += ms;
    if (stuckCk > 600) {
      if (math.sqrt((this.x - lastPosX) * (this.x - lastPosX) +
              (this.y - lastPosY) * (this.y - lastPosY)) < 0.08) {
        stuckTimer += 600;
        if (stuckTimer > 900) { _pickPatrolTarget(); stuckTimer = 0; }
      } else {
        stuckTimer = 0;
      }
      lastPosX = this.x; lastPosY = this.y; stuckCk = 0;
    }
  }

  void _doBreakout(double dt, IWorld world) {
    final door = nearestDoor;
    if (door == null || distToXY(door.x, door.y) < 1.5) _findNearestExit(world);
    final tgt = nearestDoor ??
        (x: this.x + (dir == 1 ? 5.0 : -5.0), y: this.y + 3);
    _toward(tgt, GAME.zombieAlertSpeed, dt, world);

    final fx = (this.x + (vx >= 0 ? 0.75 : -0.75)).round();
    final fy = (this.y + (vy >= 0 ? 0.75 : -0.75)).round();
    final ahead = world.get(fx, fy);
    if (ahead == TT.BWALL || ahead == TT.DOOR) {
      doorBreakTimer += dt * 1000;
      if (doorBreakTimer > GAME.doorBreakTime) {
        doorBreakTimer = 0;
        nearestDoor = (x: fx + 0.5, y: fy + 2.5);
      }
    } else {
      doorBreakTimer = 0;
    }
  }

  void _findNearestExit(IWorld world) => nearestDoor = null;

  void _gotoAlert(({double x, double y}) pos, double dur) {
    state = 'alert'; alertTarget = pos; alertTimer = dur;
  }
  void _gotoChase(Entity t) {
    state = 'chase'; lastSeen = (x: t.x, y: t.y);
    chaseTimer = GAME.zombieChaseMemory.toDouble();
  }

  void _pickPatrolTarget() {
    final a = math.Random().nextDouble() * math.pi * 2;
    final d = 3 + math.Random().nextDouble() * 10;
    patrolTarget = (
      x: (x + math.cos(a) * d).clamp(WALL_T + 1.0, 9999.0),
      y: (y + math.sin(a) * d).clamp(WALL_T + 1.0, 9999.0),
    );
    patrolTimer = 1500 + math.Random().nextDouble() * 2500;
  }

  void _doPatrol(double dt, IWorld world) {
    patrolTimer -= dt * 1000;
    if (patrolTimer <= 0) _pickPatrolTarget();
    _toward(patrolTarget, GAME.zombiePatrolSpeed, dt, world);
  }
  void _doAlert(double dt, IWorld world) {
    final tgt = alertTarget;
    if (tgt == null) { _doPatrol(dt, world); return; }
    _toward(tgt, GAME.zombieAlertSpeed, dt, world);
    if (distToXY(tgt.x, tgt.y) < 1.5) alertTarget = null;
  }
  void _doChase(double dt, IWorld world) {
    final ls = lastSeen;
    if (ls != null) _toward(ls, GAME.zombieChaseSpeed, dt, world);
  }
  void _toward(({double x, double y}) target, double speed, double dt, IWorld world) {
    final dx = target.x - x, dy = target.y - y;
    final d  = math.sqrt(dx * dx + dy * dy);
    if (d < 0.15) { vx = 0; vy = 0; return; }
    vx = (dx / d) * speed;
    vy = (dy / d) * speed;
    move(dt, world);
  }

  void draw(Canvas canvas, ({double x, double y}) cam, double cw, double ch, int now) {
    if (!alive || !onScreen(cam, cw, ch)) return;
    final px = (x - cam.x) * TS, py = (y - cam.y) * TS;
    final pw = 7 * PP, ph = 6 * PP;
    final dx2 = px + (TS - pw) / 2, dy2 = py + (TS - ph) / 2;

    fillEllipse(canvas, px + TS / 2, py + TS - 2, TS / 3, 3,
        const Color(0x33000000));
    final bodyC = state == 'chase'
        ? CLR.zombie
        : (breakoutMode ? const Color(0xFF70d470) : CLR.zombieDark);
    drawPixelSprite(canvas, getSpriteMatrix(dir), dx2, dy2, PP, bodyC, CLR.zombieEye);

    if (state != 'patrol' || breakoutMode) {
      final labelCol = breakoutMode
          ? const Color(0xFFff8800)
          : (state == 'chase' ? CLR.alertFg[2] : CLR.alertFg[1]);
      drawText(canvas, breakoutMode ? '↑' : (state == 'chase' ? '!' : '?'),
          px + TS / 2, py - 11, labelCol, PP * 3, bold: true, align: 'center');
    }

    if (hp < GAME.zombieHp) {
      fillRect(canvas, px, py - 5, TS, 3, const Color(0xFF440000));
      fillRect(canvas, px, py - 5, (TS * hp / GAME.zombieHp).roundToDouble(), 3,
          const Color(0xFF00cc00));
    }
  }

  void drawInterior(Canvas canvas, ({double x, double y}) off, int now) {
    if (!alive) return;
    final px = off.x + x * TSI, py = off.y + y * TSI;
    final pw = 7 * PPI, ph = 6 * PPI;
    final dx2 = px + (TSI - pw) / 2, dy2 = py + (TSI - ph) / 2;
    fillEllipse(canvas, px + TSI / 2, py + TSI - 2, TSI / 3, 4,
        const Color(0x33000000));
    drawPixelSprite(canvas, getSpriteMatrix(dir), dx2, dy2, PPI,
        state == 'chase' ? CLR.zombie : CLR.zombieDark, CLR.zombieEye);
  }
}

// ─── NPC ─────────────────────────────────────────────────────────────────────
class NPC extends Entity {
  ({double x, double y}) wanderTarget;
  double wanderTimer = 0, fleeTimer = 0;
  bool infected = false;
  double infectionTimer = 0;
  bool infSoundPlayed = false;
  final int colorIdx;
  final double scaleF;

  NPC(super.x, super.y)
      : wanderTarget  = (x: x, y: y),
        colorIdx      = math.Random().nextInt(4),
        scaleF        = 0.85 + math.Random().nextDouble() * 0.3;

  void update(double dt, List<Zombie> zombies, IWorld world) {
    final ms = dt * 1000;
    double nearDist = double.infinity;
    Zombie? nearZ;
    for (final z in zombies) {
      if (!z.alive) continue;
      final d = distTo(z);
      if (d < nearDist) { nearDist = d; nearZ = z; }
    }
    if (nearDist < GAME.npcFleeRange && nearZ != null) {
      fleeTimer = 2200;
      final dx = x - nearZ.x, dy = y - nearZ.y;
      final d  = math.sqrt(dx * dx + dy * dy) > 0
          ? math.sqrt(dx * dx + dy * dy)
          : 1.0;
      vx = (dx / d) * GAME.npcSpeed * 2.2;
      vy = (dy / d) * GAME.npcSpeed * 2.2;
    } else if (fleeTimer > 0) {
      fleeTimer -= ms; vx *= 0.9; vy *= 0.9;
    } else {
      wanderTimer -= ms;
      if (wanderTimer <= 0 || distToXY(wanderTarget.x, wanderTarget.y) < 1.2) {
        final a    = math.Random().nextDouble() * math.pi * 2;
        final dist = 8 + math.Random().nextDouble() * 22;
        wanderTarget = (
          x: (x + math.cos(a) * dist).clamp(WALL_T + 1.0, 9999.0),
          y: (y + math.sin(a) * dist).clamp(WALL_T + 1.0, 9999.0),
        );
        wanderTimer = 2500 + math.Random().nextDouble() * 4000;
      }
      final dx = wanderTarget.x - x, dy = wanderTarget.y - y;
      final d  = math.sqrt(dx * dx + dy * dy);
      if (d > 0.5) {
        vx = (dx / d) * GAME.npcSpeed;
        vy = (dy / d) * GAME.npcSpeed;
      } else {
        vx = 0; vy = 0;
      }
    }
    move(dt, world);
    if (infected) infectionTimer -= ms;
  }

  void draw(Canvas canvas, ({double x, double y}) cam, double cw, double ch, int now) {
    if (!alive || !onScreen(cam, cw, ch)) return;
    final px = (x - cam.x) * TS, py = (y - cam.y) * TS;
    final ps = (PP * scaleF).roundToDouble();
    final pw = 7 * ps, ph = 6 * ps;
    final dx2 = px + (TS - pw) / 2, dy2 = py + (TS - ph) / 2;

    fillEllipse(canvas, px + TS / 2, py + TS - 2, TS / 3, 2.5,
        const Color(0x2E000000));
    Color col;
    if (infected) {
      final p = (math.sin(now / 80.0) + 1) / 2;
      col = Color.fromARGB(
        255,
        (80 + p * 160).toInt(),
        (180 + p * 50).toInt(),
        (80 - p * 60).clamp(0, 255).toInt(),
      );
    } else {
      col = CLR.npcColors[colorIdx];
    }
    drawPixelSprite(canvas, getSpriteMatrix(dir), dx2, dy2, ps, col,
        const Color(0xFFf0d090));
  }
}

// ─── Item ─────────────────────────────────────────────────────────────────────
class GameItem {
  double x, y;
  final String type;
  bool collected = false;

  GameItem(this.x, this.y, this.type);

  static final Map<String, Color> _itemColors = {
    'revolver': const Color(0xFFcccccc),
    'shotgun':  const Color(0xFFaaaaaa),
    'rifle':    const Color(0xFF888888),
    'knife':    const Color(0xFFdddddd),
    'apple':    const Color(0xFFee3333),
    'chicken':  const Color(0xFFddaa22),
    'mapitem':  CLR.mapItem,
  };
  static const Map<String, String> _labels = {
    'revolver': 'R', 'shotgun': 'S', 'rifle': 'L',
    'knife': 'K', 'apple': 'A', 'chicken': 'C',
  };

  void draw(Canvas canvas, ({double x, double y}) cam, double cw, double ch, int now) {
    if (collected) return;
    final px = (x - cam.x) * TS, py = (y - cam.y) * TS;
    if (px < -16 || px > cw + 16 || py < -16 || py > ch + 16) return;
    final pulse = (math.sin(now / 400.0 + x + y) + 1) / 2;

    if (type == 'mapitem') {
      fillCircle(canvas, px + TS / 2, py + TS / 2, TS / 2 + pulse * 3,
          CLR.mapItem.withOpacity(0.4 + pulse * 0.4));
      fillRect(canvas, px + 2, py + 2, TS - 4, TS - 4,
          const Color(0xFF1a1008));
      drawText(canvas, 'M', px + TS / 2, py + 3, CLR.mapItem, TS - 4,
          bold: true, align: 'center');
      return;
    }
    fillCircle(canvas, px + TS / 2, py + TS / 2,
        TS / 2 - 1 + pulse * 2,
        const Color(0xFFFFFFFF).withOpacity(0.1 + pulse * 0.12));
    fillRect(canvas, px + 3, py + 3, TS - 6, TS - 6,
        _itemColors[type] ?? const Color(0xFFcccccc));
    drawText(canvas, _labels[type] ?? '?', px + TS / 2, py + 2,
        const Color(0xFFFFFFFF), TS - 5, bold: true, align: 'center');
  }
}

