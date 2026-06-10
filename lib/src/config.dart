import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color;

// ─── Tile / world constants ──────────────────────────────────────────────────
const double TS   = 16.0;  // world tile size in pixels
const double TSI  = 24.0;  // interior tile size in pixels
const int    CS   = 64;    // chunk size in tiles
const double PP   = 3.0;   // world sprite pixel size
const double PPI  = 4.0;   // interior sprite pixel size

const int ROAD_HALF = 4;
const int WALL_T    = 3;

// ─── Tile type IDs ───────────────────────────────────────────────────────────
class TT {
  static const int GRASS    = 0;
  static const int ROAD     = 1;
  static const int SIDEWALK = 2;
  static const int WALL     = 3;
  static const int EXIT     = 4;
  static const int BWALL    = 5;
  static const int BFLOOR   = 6;
  static const int DOOR     = 7;
  static const int WINDOW   = 8;
  static const int TREE     = 9;
  static const int BARREL   = 10;
  static const int CAR      = 11;
  static const int XWALK    = 12;
  static const int TFLIGHT  = 13;
  static const int STAIRS   = 14;
  static const int ELEVATOR = 15;
  static const int SOFA     = 16;
  static const int KITCHEN  = 17;
  static const int DESK     = 18;
  static const int DINING   = 19;
  static const int TV       = 20;
  static const int FENCE    = 21;
  static const int MAPITEM  = 22;
}

final Set<int> WALKABLE = {
  TT.GRASS, TT.ROAD, TT.SIDEWALK, TT.EXIT,
  TT.BFLOOR, TT.DOOR, TT.XWALK, TT.MAPITEM,
};

final Set<int> SEETHR = {
  TT.GRASS, TT.ROAD, TT.SIDEWALK, TT.EXIT,
  TT.BFLOOR, TT.DOOR, TT.XWALK, TT.WINDOW, TT.MAPITEM,
};

// ─── Colour palette ──────────────────────────────────────────────────────────
Color _h(int v) => Color(v | 0xFF000000);

class CLR {
  static final Color bg           = Color(0xFF060d06);
  static final Color grass        = _h(0x4a8c3a);
  static final Color grassAlt     = _h(0x428030);
  static final Color road         = _h(0x6a6a6a);
  static final Color roadEdge     = _h(0x585858);
  static final Color sidewalk     = _h(0x9898a0);
  static final Color sidewalkEdge = _h(0x888890);
  static final Color wall         = _h(0x3c3c3c);
  static final Color wallTop      = _h(0x4c4c4c);
  static final Color exitColor    = _h(0x00dd55);
  static final Color exitGlow     = _h(0x00ff88);

  static final List<Color> bwall  = [_h(0xd8d4ce), _h(0xd4c050), _h(0xc05848), _h(0xa8a8a8)];
  static final List<Color> bfloor = [_h(0xece8e2), _h(0xece090), _h(0xe8ccc0), _h(0xd8d8d8)];
  static final Color bwallDef     = _h(0xc8c4be);

  static final Color door         = _h(0x7a4820);
  static final Color doorPanel    = _h(0x5c3415);
  static final Color window       = _h(0x88b8e8);
  static final Color windowShine  = _h(0xb0d4f8);
  static final Color windowBg     = _h(0x4888c8);

  static final Color tree         = _h(0x1e6a18);
  static final Color treeMid      = _h(0x2e9028);
  static final Color treeTop      = _h(0x46b840);
  static final Color treeShin     = _h(0x5acc50);

  static final Color barrel       = _h(0x7a5818);
  static final Color barrelHl     = _h(0x9a7428);
  static final List<Color> car    = [
    _h(0xc82020), _h(0x2038c0), _h(0x208830), _h(0xc08020), _h(0x802090),
  ];
  static final Color xwalk        = _h(0x808090);
  static final Color xwalkLine    = _h(0xa0a0b0);
  static final Color tflight      = _h(0x1c1c1c);
  static final Color fence        = _h(0x706868);
  static final Color sofa         = _h(0x8a6028);
  static final Color kitchen      = _h(0xaaaaaa);
  static final Color desk         = _h(0x9a8840);
  static final Color dining       = _h(0x8a6018);
  static final Color tv           = _h(0x141414);

  static final Color hero         = _h(0xf5c518);
  static final Color heroShadow   = _h(0xc09000);
  static final Color zombie       = _h(0x50b450);
  static final Color zombieDark   = _h(0x308030);
  static final Color zombieEye    = _h(0xdd1010);
  static final List<Color> npcColors = [
    _h(0x4488ee), _h(0xee8844), _h(0x44ee88), _h(0xee4488),
  ];

  static final Color heartFull    = _h(0xcc1e1e);
  static final Color heartEmpty   = _h(0x441010);

  static final List<Color> alertBg  = [_h(0x001a08), _h(0x1a1200), _h(0x1a0000)];
  static final List<Color> alertBdr = [_h(0x006633), _h(0x886600), _h(0x880000)];
  static final List<Color> alertFg  = [_h(0x00cc44), _h(0xffcc00), _h(0xff3300)];
  static const List<String> alertLbl = ['SEGURO', 'ALERTA', 'PERIGO!'];

  static final Color mapItem      = _h(0xffe040);
  static final Color soundRing    = Color(0x26FFFF50); // rgba(255,255,80,0.15)

  // Building facade colours  0=cream 1=yellow 2=brick 3=concrete
  static final List<Color> facadeWall   = [_h(0xd8d4ce), _h(0xd4c050), _h(0xc05848), _h(0xaaaaaa)];
  static final List<Color> facadeRoof   = [_h(0x9a8870), _h(0xc0a840), _h(0x8a4030), _h(0x808080)];
  static final List<Color> facadeAccent = [_h(0x2a7a2a), _h(0xa07800), _h(0x8a2018), _h(0x505060)];
}

// ─── Game tuning ─────────────────────────────────────────────────────────────
class GAME {
  static const double playerSpeed       = 3.8;
  static const double sprintMult        = 1.7;
  static const double playerAttackRange = 1.9;
  static const double knifeRiskRange    = 2.5;

  // Progressão por fase: zumbis aumentam, sobreviventes diminuem.
  static int zombiesForPhase(int phase) =>
      math.min(110, 25 + (phase - 1) * 12);
  static int npcsForPhase(int phase) =>
      math.max(10, 80 - (phase - 1) * 12);
  static int indoorZombiesForPhase(int phase) =>
      math.min(8, 2 + phase);

  static const double zombiePatrolSpeed = 1.1;
  static const double zombieAlertSpeed  = 2.0;
  static const double zombieChaseSpeed  = 3.0;
  static const double zombieVision      = 10.0;
  static const double zombieHear        = CS * 0.25;
  static const double zombieHearIndoor  = CS * 0.125;
  static const int    zombieChaseMemory = 3000;
  static const int    zombieAlertDecay  = 6000;
  static const int    zombieAttackCd    = 1100;
  static const int    zombieHp          = 3;
  static const int    doorBreakTime     = 2500;

  static const double npcSpeed          = 1.4;
  static const double npcFleeRange      = 7.0;
  static const int    infectionDelay    = 900;

  static const int    soundWalkCd       = 480;
  static const int    invincDuration    = 1600;
  static const int    scorePerKill      = 1000;
  static const int    lifeEvery         = 10000;
  static const int    scoreMapItem      = 2000;

  static const int    baseWorldWC       = 6;
  static const int    maxWorldWC        = 10;
}
