// dart:ui provides Canvas, Paint, Rect, etc. but its TextStyle conflicts with
// Flutter's richer TextStyle used by TextPainter — we hide dart:ui.TextStyle.
import 'dart:ui' hide TextStyle;
import 'package:flutter/painting.dart';
import 'config.dart';

// ─── Pixel-art sprite matrices (7×6 grid, 1=filled) ─────────────────────────
class SPR {
  static const List<List<int>> heroDown = [
    [0,0,1,1,1,0,0],
    [0,1,0,1,0,1,0],
    [1,1,1,1,1,1,1],
    [1,1,0,0,0,1,1],
    [0,1,1,1,1,1,0],
    [0,0,1,1,1,0,0],
  ];
  static const List<List<int>> heroRight = [
    [0,0,1,1,1,1,0],
    [0,1,1,1,0,1,0],
    [1,1,1,1,1,1,1],
    [1,1,1,1,0,0,0],
    [0,1,1,1,1,1,0],
    [0,0,1,1,1,0,0],
  ];
  static const List<List<int>> heroLeft = [
    [0,1,1,1,1,0,0],
    [0,1,0,1,1,1,0],
    [1,1,1,1,1,1,1],
    [0,0,0,1,1,1,1],
    [0,1,1,1,1,1,0],
    [0,0,1,1,1,0,0],
  ];
  static const List<List<int>> heroUp = [
    [0,0,1,1,1,0,0],
    [0,1,0,1,0,1,0],
    [1,1,1,1,1,1,1],
    [1,1,1,1,1,1,1],
    [0,1,1,1,1,1,0],
    [0,0,1,1,1,0,0],
  ];
}

// Zombie eye positions (row, col) in 7×6 sprite
const List<List<int>> _zombieEyes = [
  [1, 1],
  [1, 5],
];

List<List<int>> getSpriteMatrix(int dir) {
  switch (dir) {
    case 1:  return SPR.heroRight;
    case 2:  return SPR.heroUp;
    case 3:  return SPR.heroLeft;
    default: return SPR.heroDown;
  }
}

void drawPixelSprite(
  Canvas canvas,
  List<List<int>> matrix,
  double dx,
  double dy,
  double ps,
  Color bodyColor,
  Color? eyeColor,
) {
  final bodyPaint = Paint()..color = bodyColor;
  final eyePaint  = eyeColor != null ? (Paint()..color = eyeColor) : null;
  for (int r = 0; r < matrix.length; r++) {
    for (int c = 0; c < matrix[r].length; c++) {
      if (matrix[r][c] == 0) continue;
      final bool isEye = eyePaint != null &&
          _zombieEyes.any((e) => e[0] == r && e[1] == c);
      canvas.drawRect(
        Rect.fromLTWH(dx + c * ps, dy + r * ps, ps, ps),
        isEye ? eyePaint : bodyPaint,
      );
    }
  }
}

// Deterministic building colour group (0–3) from tile coords
int bldGroup(int tx, int ty) =>
    (((tx ~/ 20) * 7 + (ty ~/ 20) * 11) ^
     ((tx ~/ 20) + (ty ~/ 20) * 3)) & 3;

// ─── Drawing helpers ─────────────────────────────────────────────────────────
void fillRect(Canvas c, double x, double y, double w, double h, Color col,
    [double alpha = 1.0]) {
  c.drawRect(
    Rect.fromLTWH(x, y, w, h),
    Paint()..color = alpha < 1.0 ? col.withOpacity(alpha) : col,
  );
}

void fillCircle(Canvas c, double cx, double cy, double r, Color col,
    [double alpha = 1.0]) {
  c.drawCircle(
    Offset(cx, cy),
    r,
    Paint()..color = alpha < 1.0 ? col.withOpacity(alpha) : col,
  );
}

void strokeRect(Canvas c, double x, double y, double w, double h, Color col,
    double lw) {
  c.drawRect(
    Rect.fromLTWH(x, y, w, h),
    Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = lw,
  );
}

void fillEllipse(Canvas c, double cx, double cy, double rx, double ry,
    Color col, [double alpha = 1.0]) {
  c.drawOval(
    Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
    Paint()..color = alpha < 1.0 ? col.withOpacity(alpha) : col,
  );
}

/// Draw text centred, right-, or left-aligned at (x, y) where y is the TOP of
/// the text.
void drawText(
  Canvas canvas,
  String text,
  double x,
  double y,
  Color color,
  double size, {
  bool bold = false,
  String align = 'left',
  String? family,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontFamily: family ?? 'monospace',
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        height: 1.0,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  tp.layout(maxWidth: double.infinity);
  double dx;
  switch (align) {
    case 'center': dx = x - tp.width / 2; break;
    case 'right':  dx = x - tp.width;     break;
    default:       dx = x;
  }
  tp.paint(canvas, Offset(dx, y));
}
