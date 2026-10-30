import 'package:flutter/material.dart';
import 'feed.dart';
import 'filters.dart';
import 'gallery.dart';
import 'keyword_ui.dart';

/// Gallery grid or feed (Card/Slides/Compact), following the chosen post layout.
class PostsView extends StatelessWidget {
  final String? title;
  final bool sources;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? header;
  final VoidCallback? onTitleTap;
  const PostsView({super.key, this.title, this.sources = true, this.leading, this.actions = const [], this.header, this.onTitleTap});
  @override
  Widget build(BuildContext context) {
    final header = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [?this.header, const KeywordChips()]);
    return ValueListenableBuilder(
        valueListenable: postLayout,
        builder: (_, l, _) => l == PostLayout.gallery
            ? GalleryScreen(key: const ValueKey('g'), title: title, sources: sources, leading: leading, actions: actions, header: header, onTitleTap: onTitleTap)
            : FeedScreen(key: const ValueKey('f'), title: title, sources: sources, leading: leading, actions: actions, header: header, onTitleTap: onTitleTap),
      );
  }
}
