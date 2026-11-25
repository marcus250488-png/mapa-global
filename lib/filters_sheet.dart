import 'package:flutter/material.dart';

import 'controller.dart';
import 'filters.dart';
import 'format.dart';
import 'models.dart';

const _muted = TextStyle(fontSize: 13.5, color: Palette.muted);

/// Todos os filtros do mapa e da lista.
class FiltersSheet extends StatelessWidget {
  const FiltersSheet({
    super.key,
    required this.data,
    required this.onSetHomeHere,
  });

  final EventsController data;

  /// Marca o centro do mapa como "meu local".
  final VoidCallback onSetHomeHere;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final f = data.filters;
        final home = data.prefs.home;
        void set(MapFilters n) => data.updateFilters(n);

        const severities = <(Severity, String)>[
          (Severity.low, 'Qualquer'),
          (Severity.moderate, 'Moderada ou mais'),
          (Severity.high, 'Alta ou mais'),
          (Severity.extreme, 'Só extrema'),
        ];
        const periods = <(int, String)>[
          (6, '6 h'),
          (24, '24 h'),
          (72, '3 dias'),
          (168, '7 dias'),
          (0, 'Tudo'),
        ];
        const radii = <(int, String)>[
          (0, 'Sem limite'),
          (100, '100 km'),
          (250, '250 km'),
          (500, '500 km'),
          (1000, '1.000 km'),
          (2500, '2.500 km'),
        ];

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Filtros',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Palette.ink,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed:
                          f.isDefault ? null : () => set(const MapFilters()),
                      child: const Text('Restaurar padrão'),
                    ),
                  ],
                ),
                const _Section('Região (aproximada)'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in Region.values)
                      ChoiceChip(
                        label: Text(r.label),
                        selected: f.region == r,
                        onSelected: (_) => set(f.copyWith(region: r)),
                      ),
                  ],
                ),
                const _Section('Tipo de evento'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in HazardType.values)
                      FilterChip(
                        label: Text(t.label),
                        avatar: Icon(Icons.circle, size: 10, color: t.color),
                        selected: f.types.contains(t),
                        showCheckmark: false,
                        onSelected: (on) {
                          final next = {...f.types};
                          if (on) {
                            next.add(t);
                          } else if (next.length > 1) {
                            next.remove(t);
                          }
                          set(f.copyWith(types: next));
                        },
                      ),
                  ],
                ),
                const _Section('Gravidade mínima'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (sev, label) in severities)
                      ChoiceChip(
                        label: Text(label),
                        selected: f.minSeverity == sev,
                        onSelected: (_) => set(f.copyWith(minSeverity: sev)),
                      ),
                  ],
                ),
                _Section('Magnitude mínima dos terremotos: ${num1(f.minMag)}'),
                Slider(
                  min: 4.5,
                  max: 8.0,
                  divisions: 7,
                  value: f.minMag.clamp(4.5, 8.0).toDouble(),
                  label: num1(f.minMag),
                  onChanged: (v) =>
                      set(f.copyWith(minMag: (v * 2).round() / 2)),
                ),
                const _Section('Período'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (h, label) in periods)
                      ChoiceChip(
                        label: Text(label),
                        selected: f.hours == h,
                        onSelected: (_) => set(f.copyWith(hours: h)),
                      ),
                  ],
                ),
                const _Section('Perto de mim'),
                Text(
                  home == null
                      ? 'Meu local não definido. Toque e segure no mapa, ou use o botão abaixo para marcar o centro do mapa.'
                      : 'Meu local: ${coords(home)}',
                  style: _muted,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: onSetHomeHere,
                      icon: const Icon(Icons.my_location, size: 18),
                      label: const Text('Usar o centro do mapa'),
                    ),
                    if (home != null)
                      OutlinedButton(
                        onPressed: () => data.setHome(null),
                        child: const Text('Limpar'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (km, label) in radii)
                      ChoiceChip(
                        label: Text(label),
                        selected: f.radiusKm == km,
                        onSelected: home == null
                            ? null
                            : (_) => set(f.copyWith(radiusKm: km)),
                      ),
                  ],
                ),
                const _Section('Ordenar por'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in SortBy.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: f.sort == s,
                        onSelected: (s == SortBy.nearest && home == null)
                            ? null
                            : (_) => set(f.copyWith(sort: s)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Palette.ink,
        ),
      ),
    );
  }
}
