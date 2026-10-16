import 'package:flutter/material.dart';

class SourceRatingBadge extends StatelessWidget {
  const SourceRatingBadge({super.key});
  @override
  Widget build(BuildContext context) => const Tooltip(
    message: '含成人内容 · 18+',
    child: Icon(Icons.eighteen_up_rating_outlined, size: 18),
  );
}
