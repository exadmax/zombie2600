import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/game.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
    [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  );
  runApp(const ZombieApp());
}

class ZombieApp extends StatelessWidget {
  const ZombieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Zombie 2600',
      debugShowCheckedModeBanner: false,
      home: GameWidget(),
    );
  }
}
