import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'controller.dart';
import 'format.dart';
import 'models.dart';
import 'notifier.dart';
import 'prefs.dart';
import 'sources.dart';

const _appId = 'com.monitorglobal.monitor_global';

/// Mapa-base em tons de cinza: a cor fica reservada para os eventos.
const _gray = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
]);

const _muted = TextStyle(fontSize: 13.5, color: Palette.muted);
const _tabular = [FontFeature.tabularFigures()];

Future<void> _open(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    // Sem navegador disponível: ignora.
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _data = EventsController();
  final _map = MapController();
  final _sheet = DraggableScrollableController();

  @override
  void dispose() {
    _data.dispose();
    _sheet.dispose();
    super.dispose();
  }

  void _showEvent(HazardEvent e, {bool fly = false}) {
    if (fly) {
      _map.move(e.point, math.max(_map.camera.zoom, 5.0));
      if (_sheet.isAttached) {
        _sheet.animateTo(
          0.16,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Palette.paper,
      builder: (_) => EventDetails(
        event: e,
        onConditions: () {
          Navigator.pop(context);
          _showConditions(e.point);
        },
      ),
    );
  }

  void _showConditions(LatLng p) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Palette.paper,
      builder: (_) => ConditionsSheet(point: p),
    );
  }

  void _showAbout() {
    showDialog<void>(context: context, builder: (_) => const _AboutDialog());
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Palette.paper,
      builder: (_) => AlertSettingsSheet(data: _data),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _data,
      builder: (context, _) {
        final events = _data.visible;
        return Scaffold(
          body: Stack(
            children: [
              _buildMap(context, events),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopPanel(
                  data: _data,
                  onAbout: _showAbout,
                  onSettings: _showSettings,
                ),
              ),
              _EventsSheet(
                controller: _sheet,
                events: events,
                loading: _data.loading,
                onSelect: (e) => _showEvent(e, fly: true),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMap(BuildContext context, List<HazardEvent> events) {
    final radar = _data.radar;
    final radarOn = _data.enabled.contains(MapLayer.radar);
    final bottomPad = MediaQuery.sizeOf(context).height * 0.17;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: const LatLng(18, 10),
        initialZoom: 2.2,
        minZoom: 1.5,
        maxZoom: 12,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onTap: (_, point) => _showConditions(point),
      ),
      children: [
        ColorFiltered(
          colorFilter: _gray,
          child: TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: _appId,
          ),
        ),
        if (radarOn && radar != null)
          Opacity(
            opacity: 0.75,
            child: TileLayer(
              urlTemplate: radar.tileUrl,
              userAgentPackageName: _appId,
              maxNativeZoom: 7,
            ),
          ),
        PolygonLayer(
          polygons: [
            for (final e in events)
              if (e.area.isNotEmpty)
                Polygon(
                  points: e.area,
                  color: e.type.color.withAlpha(46),
                  borderColor: e.type.color,
                  borderStrokeWidth: 2,
                ),
          ],
        ),
        MarkerLayer(
          markers: [
            // Os mais graves por último, para ficarem por cima.
            for (final e in events.reversed)
              Marker(
                point: e.point,
                width: e.severity.markerSize + 14,
                height: e.severity.markerSize + 14,
                child: GestureDetector(
                  onTap: () => _showEvent(e),
                  child: _HazardDot(event: e),
                ),
              ),
          ],
        ),
        Padding(
          padding: EdgeInsets.only(bottom: bottomPad),
          child: RichAttributionWidget(
            attributions: [
              TextSourceAttribution(
                'OpenStreetMap contributors',
                onTap: () => _open('https://www.openstreetmap.org/copyright'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Marcador no mapa
// ---------------------------------------------------------------------------

class _HazardDot extends StatelessWidget {
  const _HazardDot({required this.event});

  final HazardEvent event;

  @override
  Widget build(BuildContext context) {
    final size = event.severity.markerSize;
    final color = event.type.color;
    final strong = event.severity.index >= Severity.high.index;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: strong
              ? [BoxShadow(color: color.withAlpha(90), spreadRadius: 5)]
              : null,
        ),
        child: Icon(event.type.icon, size: size * 0.55, color: Colors.white),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, this.size = 38});

  final HazardType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
      child: Icon(type.icon, color: Colors.white, size: size * 0.55),
    );
  }
}

// ---------------------------------------------------------------------------
// Painel superior: título, atualização e camadas
// ---------------------------------------------------------------------------

class _TopPanel extends StatelessWidget {
  const _TopPanel({
    required this.data,
    required this.onAbout,
    required this.onSettings,
  });

  final EventsController data;
  final VoidCallback onAbout;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final status = data.loading
        ? 'Atualizando…'
        : data.updatedAt == null
            ? ''
            : 'Atualizado às ${hhmm(data.updatedAt!)}';
    final failed = data.errors.keys.toList();
    final radar = data.radar;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Material(
          color: Palette.paper,
          elevation: 3,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Monitor Global',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Palette.ink,
                            ),
                          ),
                          Row(
                            children: [
                              if (data.liveConnected) ...[
                                const Icon(
                                  Icons.circle,
                                  size: 9,
                                  color: Color(0xFF2B8A3E),
                                ),
                                const SizedBox(width: 5),
                                const Text(
                                  'Ao vivo',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF2B8A3E),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                status,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: Palette.muted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Atualizar',
                      onPressed: data.loading ? null : data.refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: 'Avisos',
                      onPressed: onSettings,
                      icon: const Icon(Icons.notifications_none),
                    ),
                    IconButton(
                      tooltip: 'Fontes e aviso',
                      onPressed: onAbout,
                      icon: const Icon(Icons.info_outline),
                    ),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final layer in MapLayer.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _LayerChip(layer: layer, data: data),
                        ),
                    ],
                  ),
                ),
                if (data.enabled.contains(MapLayer.radar) && radar != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: GestureDetector(
                      onTap: () => _open('https://www.rainviewer.com/'),
                      child: Text(
                        'Radar de ${hhmm(radar.time)}. Weather data by RainViewer',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Palette.muted,
                        ),
                      ),
                    ),
                  ),
                if (failed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Sem resposta: ${failed.join(", ")}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFFB02A37),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  const _LayerChip({required this.layer, required this.data});

  final MapLayer layer;
  final EventsController data;

  @override
  Widget build(BuildContext context) {
    final on = data.enabled.contains(layer);
    final color = layer.color;
    return FilterChip(
      label: Text(layer.label),
      avatar: Icon(Icons.circle, size: 10, color: color),
      selected: on,
      showCheckmark: false,
      onSelected: (_) => data.toggle(layer),
      backgroundColor: Colors.white,
      selectedColor: color.withAlpha(36),
      side: BorderSide(color: on ? color : Palette.line),
      labelStyle: TextStyle(
        color: on ? color : Palette.ink,
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

// ---------------------------------------------------------------------------
// Lista de eventos (folha arrastável)
// ---------------------------------------------------------------------------

class _EventsSheet extends StatelessWidget {
  const _EventsSheet({
    required this.controller,
    required this.events,
    required this.loading,
    required this.onSelect,
  });

  final DraggableScrollableController controller;
  final List<HazardEvent> events;
  final bool loading;
  final ValueChanged<HazardEvent> onSelect;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: 0.16,
      minChildSize: 0.09,
      maxChildSize: 0.9,
      snap: true,
      snapSizes: const [0.16, 0.5],
      builder: (context, scroll) {
        return Material(
          color: Palette.paper,
          elevation: 10,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(child: _SheetHeader(count: events.length)),
              if (events.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      loading
                          ? 'Buscando eventos…'
                          : 'Nenhum evento nas camadas ligadas.',
                      style: _muted,
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _EventRow(
                      event: events[i],
                      onTap: () => onSelect(events[i]),
                    ),
                    childCount: events.length,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: Palette.line,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Text(
                count == 1 ? '1 evento ativo' : '$count eventos ativos',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Palette.ink,
                ),
              ),
              const Spacer(),
              const Text(
                'Mais graves primeiro',
                style: TextStyle(fontSize: 12.5, color: Palette.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.onTap});

  final HazardEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final place = event.place;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Palette.line, width: 0.8)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            _TypeBadge(type: event.type),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Palette.ink,
                      fontFeatures: _tabular,
                    ),
                  ),
                  if (place != null && place.isNotEmpty)
                    Text(
                      place,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _muted,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(ago(event.time), style: _muted),
                Text(
                  event.severity.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: event.type.color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detalhes de um evento
// ---------------------------------------------------------------------------

class EventDetails extends StatelessWidget {
  const EventDetails({
    super.key,
    required this.event,
    required this.onConditions,
  });

  final HazardEvent event;
  final VoidCallback onConditions;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final place = e.place;
    final detail = e.detail;
    final url = e.url;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _TypeBadge(type: e.type, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.type.label}, gravidade ${e.severity.label.toLowerCase()}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: e.type.color,
                        ),
                      ),
                      Text(
                        e.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Palette.ink,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (place != null && place.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                place,
                style: const TextStyle(fontSize: 15.5, color: Palette.ink),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '${dayHhmm(e.time)} (${ago(e.time)}). Fonte: ${e.source}.',
              style: _muted,
            ),
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 14.5,
                  height: 1.35,
                  color: Palette.ink,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onConditions,
                  icon: const Icon(Icons.air),
                  label: const Text('Vento e instabilidade aqui'),
                ),
                if (url != null)
                  OutlinedButton.icon(
                    onPressed: () => _open(url),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Abrir fonte'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Condições num ponto qualquer do mapa (Open-Meteo)
// ---------------------------------------------------------------------------

class ConditionsSheet extends StatefulWidget {
  const ConditionsSheet({super.key, required this.point});

  final LatLng point;

  @override
  State<ConditionsSheet> createState() => _ConditionsSheetState();
}

class _ConditionsSheetState extends State<ConditionsSheet> {
  late final Future<PointWeather> _future = fetchPointWeather(widget.point);

  @override
  Widget build(BuildContext context) {
    final title = Text(
      'Condições em ${coords(widget.point)}',
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Palette.ink,
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: FutureBuilder<PointWeather>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 24),
                ],
              );
            }
            final w = snap.data;
            if (snap.hasError || w == null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 12),
                  const Text(
                    'Não foi possível carregar a previsão agora. Tente de novo em instantes.',
                    style: _muted,
                  ),
                  const SizedBox(height: 8),
                ],
              );
            }
            final dir = w.direction == null ? '' : ', de ${compass(w.direction!)}';
            final wind = w.wind == null ? '--' : '${w.wind!.round()} km/h$dir';
            final gust = w.gust == null ? '--' : '${w.gust!.round()} km/h';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 10),
                _Metric('Vento agora', wind),
                _Metric('Rajadas agora', gust),
                _Metric('Pico de rajadas em 24 h', '${w.gustPeak.round()} km/h'),
                _Metric(
                  'Instabilidade (CAPE), pico em 24 h',
                  '${int0(w.capePeak)} J/kg, ${capeLabel(w.capePeak)}',
                ),
                _Metric('Chuva prevista em 24 h', '${num1(w.rain)} mm'),
                const SizedBox(height: 12),
                const Text(
                  'Previsão de modelo (Open-Meteo), não é alerta oficial. '
                  'CAPE alto indica potencial para tempestades fortes, '
                  'mas não confirma tornados.',
                  style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.muted),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: Text(label, style: _muted)),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: Palette.ink,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fontes e aviso
// ---------------------------------------------------------------------------

class _AboutDialog extends StatelessWidget {
  const _AboutDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Palette.paper,
      title: const Text('Fontes e aviso'),
      content: const SingleChildScrollView(
        child: Text(
          'Terremotos: USGS e EMSC (tempo real, CC BY 4.0).\n'
          'Ciclones, enchentes, vulcões, incêndios e secas: GDACS (ONU e Comissão Europeia).\n'
          'Avisos de tornado, tempestade severa e enchente repentina: National Weather Service (EUA).\n'
          'Vento e instabilidade: Open-Meteo.\n'
          'Radar: RainViewer.\n'
          'Mapa: © OpenStreetMap contributors.\n\n'
          'O Monitor Global é informativo e não substitui os avisos oficiais. '
          'Em caso de emergência, siga as orientações da Defesa Civil e do '
          'serviço meteorológico do seu país.',
          style: TextStyle(height: 1.4),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fechar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ajustes dos avisos no celular
// ---------------------------------------------------------------------------

class AlertSettingsSheet extends StatefulWidget {
  const AlertSettingsSheet({super.key, required this.data});

  final EventsController data;

  @override
  State<AlertSettingsSheet> createState() => _AlertSettingsSheetState();
}

class _AlertSettingsSheetState extends State<AlertSettingsSheet> {
  late AlertPrefs _p = widget.data.prefs;
  String _msg = '';

  void _set(AlertPrefs p) {
    setState(() => _p = p);
    widget.data.updatePrefs(p);
  }

  Future<void> _permission() async {
    var ok = false;
    try {
      ok = await Notifier.requestPermission();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _msg = ok
          ? 'Notificações ativadas.'
          : 'Permissão não concedida. Ative em Configurações do Android, Apps, Monitor Global, Notificações.';
    });
  }

  Future<void> _test() async {
    String msg;
    try {
      await Notifier.sendTest();
      msg = 'Aviso de teste enviado.';
    } catch (_) {
      msg = 'Não foi possível enviar o aviso de teste.';
    }
    if (!mounted) return;
    setState(() => _msg = msg);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Avisos no celular',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Palette.ink,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Terremotos'),
              subtitle: Text('Magnitude ${num1(_p.minMag)} ou maior'),
              value: _p.quakes,
              onChanged: (v) => _set(_p.copyWith(quakes: v)),
            ),
            Slider(
              min: 4.5,
              max: 8.0,
              divisions: 7,
              value: _p.minMag.clamp(4.5, 8.0).toDouble(),
              label: num1(_p.minMag),
              onChanged: _p.quakes
                  ? (v) => _set(_p.copyWith(minMag: (v * 2).round() / 2))
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ciclones e desastres'),
              subtitle: const Text('Alerta laranja ou vermelho (GDACS)'),
              value: _p.disasters,
              onChanged: (v) => _set(_p.copyWith(disasters: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Avisos extremos dos EUA'),
              subtitle: const Text('Tornado e vento extremo (NWS)'),
              value: _p.alerts,
              onChanged: (v) => _set(_p.copyWith(alerts: v)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _permission,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Ativar notificações'),
                ),
                OutlinedButton.icon(
                  onPressed: _test,
                  icon: const Icon(Icons.send_outlined, size: 18),
                  label: const Text('Enviar teste'),
                ),
              ],
            ),
            if (_msg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_msg, style: _muted),
              ),
            const SizedBox(height: 14),
            const Text(
              'Com o app aberto, o aviso chega assim que a fonte publica (terremotos pelo EMSC, sem esperar a consulta). '
              'Com o app fechado, o Android só deixa checar a cada 15 minutos, no '
              'mínimo, e pode atrasar mais quando a tela fica apagada por muito '
              'tempo. Para atrasar menos, em Configurações do Android, Apps, '
              'Monitor Global, Bateria, escolha "Sem restrições". Avisos em '
              'segundos com o app fechado dependem de um servidor (Firebase), '
              'que fica para uma próxima versão.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: Palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
