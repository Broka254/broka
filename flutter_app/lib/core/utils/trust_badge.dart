// BROKA v3.0 - Trust Score UI helpers
import 'package:flutter/material.dart';

Color trustScoreColor(int score) {
  if (score >= 80) return const Color(0xFF22C55E);  // green
  if (score >= 50) return const Color(0xFFF59E0B);  // amber
  if (score >= 20) return const Color(0xFFEF4444);  // red
  return const Color(0xFF7F1D1D);                    // dark red
}

String trustScoreLabel(int score) {
  if (score >= 80) return 'Trusted';
  if (score >= 50) return 'Standard';
  if (score >= 20) return 'At Risk';
  return 'High Risk';
}

Widget trustBadge(int score, {double size = 12}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: trustScoreColor(score).withOpacity(0.15),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: trustScoreColor(score), width: 0.8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.shield, size: size, color: trustScoreColor(score)),
        const SizedBox(width: 3),
        Text(
          '$score · ${trustScoreLabel(score)}',
          style: TextStyle(
            fontSize: size,
            color: trustScoreColor(score),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
