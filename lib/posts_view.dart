import 'package:flutter/material.dart';
import 'feed.dart';
import 'filters.dart';
import 'gallery.dart';

/// Gallery grid or feed (Card/Slides/Compact), following the chosen post layout.
class PostsView extends StatelessWidget {
  final String? title;
  final bool sources;
  final Widget? leading;
  final List<Widget> actions;
  const PostsView({super.key, this.title, this.sources = true, this.leading, this.actions = const []});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: postLayout,
        builder: (_, l, _) => l == PostLayout.gallery
            ? GalleryScreen(key: const ValueKey('g'), title: title, sources: sources, leading: leading, actions: actions)
            : FeedScreen(key: const ValueKey('f'), title: title, sources: sources, leading: leading, actions: actions),
      );
}
