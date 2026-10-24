import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../shared/widgets/source_translation.dart';
import 'poster_card.dart';
import 'section_toolbar.dart';

/// Logical-pixel dimensions for the reference three-column search layout.
abstract final class AggregateSearchLayout {
  static const columns = 3;
  static const gridPadding = 8.0;
  static const columnGap = 8.0;
  static const rowGap = 18.0;
  static const coverHeightRatio = 1.4;
  static const coverRadius = 10.0;
  static const titleGap = 6.0;
  static const titleSize = 13.0;
  static const titleLineHeight = 1.25;
  static const dividerSlotWidth = 1.0;
  static const siteRowMinHeight = 44.0;
  static const siteRowRadius = 6.0;
  static const selectedSiteOpacity = .07;
  static const selectedIndicatorWidth = 2.0;
  static const selectedIndicatorHeight = 18.0;
  static const dividerOpacity = .10;
  static const siteSeparatorOpacity = .16;

  // One sidebar plus three equally wide covers share the remaining width.
  static double sidebarWidth(double width) =>
      (width - dividerSlotWidth - 2 * gridPadding - (columns - 1) * columnGap) /
      (columns + 1);
  static double cellWidth(double width) =>
      (width - 2 * gridPadding - (columns - 1) * columnGap) / columns;
  static double itemExtent(double width, double textScale) =>
      cellWidth(width) * coverHeightRatio +
      titleGap +
      titleSize * titleLineHeight * textScale;
}

/// Search keeps its one-line caption below the cover, independently of the
/// reader's global overlay-title preference. Complete metadata stays available.
class AggregateSearchPoster extends StatelessWidget {
  const AggregateSearchPoster({
    super.key,
    required this.hit,
    required this.metadata,
    required this.onTap,
    this.pipeline,
  });
  final SearchHit hit;
  final String metadata;
  final VoidCallback onTap;
  final SectionImagePipeline? pipeline;

  String get _badge {
    final duration = hit.item.duration;
    if (duration != null) {
      final seconds = '${duration.inSeconds.remainder(60)}'.padLeft(2, '0');
      return '${duration.inMinutes}:$seconds';
    }
    final subtitle = hit.item.subtitle?.trim() ?? '';
    return subtitle.isNotEmpty ? subtitle : '来源 ${hit.sourceName}';
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(minScaleFactor: 1, maxScaleFactor: 2);
    return Tooltip(
      message: '${hit.item.title}\n$metadata',
      child: Semantics(
        button: true,
        label: '${hit.item.title}，$metadata',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(
              AggregateSearchLayout.coverRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => ClipRRect(
                      key: ValueKey(
                        'search-cover-${hit.sourceId}-${hit.item.id}',
                      ),
                      borderRadius: BorderRadius.circular(
                        AggregateSearchLayout.coverRadius,
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CoverThumb(
                            title: hit.item.title,
                            pipeline: pipeline,
                            url: hit.item.cover,
                            headers: hit.item.coverHeaders,
                            width:
                                (constraints.maxWidth *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .ceil()
                                    .clamp(1, 1200),
                          ),
                          Positioned(
                            left: 5,
                            right: 5,
                            bottom: 5,
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .55),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _badge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textScaler: MediaQuery.textScalerOf(context)
                                      .clamp(
                                        minScaleFactor: 1,
                                        maxScaleFactor: 1.4,
                                      ),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    height: 1.2,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AggregateSearchLayout.titleGap),
                SizedBox(
                  height:
                      scaler.scale(AggregateSearchLayout.titleSize) *
                      AggregateSearchLayout.titleLineHeight,
                  child: MediaQuery.withClampedTextScaling(
                    minScaleFactor: 1,
                    maxScaleFactor: 2,
                    child: SourceText(
                      hit.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: AggregateSearchLayout.titleSize,
                        height: AggregateSearchLayout.titleLineHeight,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
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
