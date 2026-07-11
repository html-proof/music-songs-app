import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/playlist_provider.dart';
import '../providers/preferences_provider.dart';
import '../services/playlist_import_service.dart';
import '../theme/app_theme.dart';

class PlaylistImportScreen extends StatefulWidget {
  final String? targetPlaylistId;
  const PlaylistImportScreen({super.key, this.targetPlaylistId});

  @override
  State<PlaylistImportScreen> createState() => _PlaylistImportScreenState();
}

class _PlaylistImportScreenState extends State<PlaylistImportScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();

  late TabController _tabController;

  _ImportPhase _phase = _ImportPhase.input;
  List<PlaylistImportItem> _previewItems = [];
  PlaylistImportResult? _result;
  String? _errorMessage;
  double _progress = 0;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    // Listen to changes to enable/disable the preview button
    _textController.addListener(_onTextChanged);
    _urlController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    _nameController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Import Playlist'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _handleBack,
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: _buildPhaseContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case _ImportPhase.input:
        return _buildInputPhase();
      case _ImportPhase.preview:
        return _buildPreviewPhase();
      case _ImportPhase.importing:
        return _buildImportingPhase();
      case _ImportPhase.results:
        return _buildResultsPhase();
    }
  }

  // ─── Input Phase ────────────────────────────────────────────

  Widget _buildInputPhase() {
    return Column(
      key: const ValueKey('input'),
      children: [
        const SizedBox(height: 8),
        _buildInfoCard(),
        const SizedBox(height: 16),
        TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.accentPurple,
          labelColor: AppTheme.textPrimary,
          unselectedLabelColor: AppTheme.textMuted,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(icon: Icon(Icons.text_snippet_rounded), text: 'Paste Text'),
            Tab(icon: Icon(Icons.link_rounded), text: 'From URL'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildTextInput(),
              _buildUrlInput(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.accentPurple.withValues(alpha: 0.15),
            AppTheme.accentPurple.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.accentPurple.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentPurple.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.swap_horiz_rounded,
              color: AppTheme.accentPurple,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Import from Any Music App',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Paste your playlist as text or share a link from Spotify, YouTube, or Apple Music.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextInput() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste your songs — one per line',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Format:  Song Name - Artist Name',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppTheme.accentPurple.withValues(alpha: 0.2),
                ),
              ),
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  height: 1.6,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Blinding Lights - The Weeknd\nBohemian Rhapsody - Queen\nShape of You - Ed Sheeran\nStay - Justin Bieber\n...',
                  hintStyle: TextStyle(
                    color: AppTheme.textMuted.withValues(alpha: 0.5),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildActionButton(
            label: 'Preview Songs',
            icon: Icons.preview_rounded,
            loading: _isProcessing,
            onPressed: (_textController.text.trim().isEmpty || _isProcessing)
                ? null
                : () => _handlePreview('text', _textController.text),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlInput() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste a playlist link',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.surfaceDark,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.accentPurple.withValues(alpha: 0.2),
              ),
            ),
            child: TextField(
              controller: _urlController,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: 'https://open.spotify.com/playlist/...',
                hintStyle: TextStyle(
                  color: AppTheme.textMuted.withValues(alpha: 0.5),
                ),
                prefixIcon: const Icon(
                  Icons.link_rounded,
                  color: AppTheme.textMuted,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSupportedPlatforms(),
          const Spacer(),
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _buildActionButton(
            label: 'Preview Songs',
            icon: Icons.preview_rounded,
            loading: _isProcessing,
            onPressed: (_urlController.text.trim().isEmpty || _isProcessing)
                ? null
                : () => _handlePreview('url', _urlController.text),
          ),
        ],
      ),
    );
  }

  Widget _buildSupportedPlatforms() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _platformChip('Spotify', Icons.music_note_rounded, Colors.green),
        _platformChip('YouTube Music', Icons.play_circle_rounded, Colors.red),
        _platformChip('Apple Music', Icons.apple_rounded, Colors.white70),
      ],
    );
  }

  Widget _platformChip(String name, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            name,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Preview Phase ──────────────────────────────────────────

  Widget _buildPreviewPhase() {
    return Column(
      key: const ValueKey('preview'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.playlist_add_check_rounded,
                  color: AppTheme.accentPurple, size: 24),
              const SizedBox(width: 8),
              Text(
                '${_previewItems.length} songs found',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Playlist name input
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.surfaceDark,
              borderRadius: BorderRadius.circular(14),
            ),
            child: TextField(
              controller: _nameController,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: 'Playlist name',
                hintStyle: TextStyle(
                  color: AppTheme.textMuted.withValues(alpha: 0.6),
                ),
                prefixIcon: const Icon(
                  Icons.edit_rounded,
                  color: AppTheme.textMuted,
                  size: 20,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _previewItems.length,
            itemBuilder: (context, index) {
              final item = _previewItems[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.accentPurple.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          color: AppTheme.accentPurple,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (item.artist.isNotEmpty)
                            Text(
                              item.artist,
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: _buildActionButton(
            label: 'Import ${_previewItems.length} Songs',
            icon: Icons.download_rounded,
            onPressed: _isProcessing ? null : _handleImport,
            gradient: true,
          ),
        ),
      ],
    );
  }

  // ─── Importing Phase ────────────────────────────────────────

  Widget _buildImportingPhase() {
    return Center(
      key: const ValueKey('importing'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    strokeWidth: 4,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppTheme.accentPurple,
                    ),
                    backgroundColor: AppTheme.surfaceDark,
                  ),
                ),
                Text(
                  _progress > 0
                      ? '${(_progress * 100).toInt()}%'
                      : '...',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Matching songs...',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Searching for each song in your playlist.\nThis may take a moment.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Results Phase ──────────────────────────────────────────

  Widget _buildResultsPhase() {
    final result = _result;
    if (result == null || result.hasError) {
      return Center(
        key: const ValueKey('error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.redAccent, size: 64),
            const SizedBox(height: 16),
            Text(
              result?.errorMessage ?? 'Something went wrong',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 24),
            _buildActionButton(
              label: 'Try Again',
              icon: Icons.refresh_rounded,
              onPressed: () => setState(() => _phase = _ImportPhase.input),
            ),
          ],
        ),
      );
    }

    return Column(
      key: const ValueKey('results'),
      children: [
        const SizedBox(height: 8),
        _buildResultsHeader(result),
        const SizedBox(height: 12),
        Expanded(child: _buildResultsList(result)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result.matched.isNotEmpty)
                _buildActionButton(
                  label: widget.targetPlaylistId != null
                      ? 'Add to Playlist (${result.matched.length} songs)'
                      : 'Create Playlist (${result.matched.length} songs)',
                  icon: Icons.playlist_add_rounded,
                  onPressed: () => _handleCreatePlaylist(result),
                  gradient: true,
                ),
              if (result.unmatched.isNotEmpty &&
                  result.matched.isNotEmpty)
                const SizedBox(height: 8),
              if (result.matched.isEmpty)
                _buildActionButton(
                  label: 'Try Again',
                  icon: Icons.refresh_rounded,
                  onPressed: () =>
                      setState(() => _phase = _ImportPhase.input),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultsHeader(PlaylistImportResult result) {
    final matchColor = result.matchRate >= 80
        ? Colors.greenAccent
        : result.matchRate >= 50
            ? Colors.amberAccent
            : Colors.redAccent;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            matchColor.withValues(alpha: 0.1),
            AppTheme.surfaceDark.withValues(alpha: 0.5),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: matchColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          // Match rate circle
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: result.matchRate / 100,
                    strokeWidth: 4,
                    valueColor: AlwaysStoppedAnimation<Color>(matchColor),
                    backgroundColor: AppTheme.surfaceDark,
                  ),
                ),
                Text(
                  '${result.matchRate}%',
                  style: TextStyle(
                    color: matchColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${result.matched.length} of ${result.totalCount} matched',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                if (result.unmatched.isNotEmpty)
                  Text(
                    '${result.unmatched.length} songs couldn\'t be found',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList(PlaylistImportResult result) {
    final allItems = <Widget>[];

    if (result.matched.isNotEmpty) {
      allItems.add(_buildSectionHeader(
        'Matched Songs',
        Icons.check_circle_rounded,
        Colors.greenAccent,
      ));
      for (final item in result.matched) {
        allItems.add(_buildMatchedSongTile(item));
      }
    }

    if (result.unmatched.isNotEmpty) {
      allItems.add(const SizedBox(height: 8));
      allItems.add(_buildSectionHeader(
        'Not Found',
        Icons.help_outline_rounded,
        Colors.orangeAccent,
      ));
      for (final item in result.unmatched) {
        allItems.add(_buildUnmatchedTile(item));
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: allItems,
    );
  }

  Widget _buildSectionHeader(String text, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchedSongTile(MatchedSong item) {
    final song = item.song;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.cardDark.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: song.imageUrl != null
                ? Image.network(
                    song.imageUrl!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder(),
                  )
                : _imagePlaceholder(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.name,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (song.artist != null && song.artist!.isNotEmpty)
                  Text(
                    song.artist!,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const Icon(
            Icons.check_circle_rounded,
            color: Colors.greenAccent,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildUnmatchedTile(UnmatchedItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.music_off_rounded,
              size: 20, color: Colors.orangeAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.artist.isNotEmpty)
                  Text(
                    item.artist,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _imagePlaceholder() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        color: AppTheme.textMuted,
        size: 22,
      ),
    );
  }

  // ─── Shared Widgets ─────────────────────────────────────────

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool gradient = false,
    bool loading = false,
  }) {
    final effectiveIcon = loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          )
        : Icon(icon, size: 20);

    if (gradient) {
      return Container(
        decoration: BoxDecoration(
          gradient: onPressed != null
              ? AppTheme.primaryGradient
              : null,
          color: onPressed == null ? AppTheme.surfaceDark : null,
          borderRadius: BorderRadius.circular(30),
        ),
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: effectiveIcon,
          label: Text(label),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
        ),
      );
    }

    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: effectiveIcon,
      label: Text(label),
    );
  }

  // ─── Actions ────────────────────────────────────────────────

  void _handleBack() {
    if (_phase == _ImportPhase.preview) {
      setState(() => _phase = _ImportPhase.input);
    } else if (_phase == _ImportPhase.results) {
      setState(() => _phase = _ImportPhase.preview);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handlePreview(String type, String content) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      if (type == 'text') {
        // Parse locally for instant feedback
        final items = PlaylistImportService.parseTextLocally(content);
        setState(() {
          _previewItems = items;
          _nameController.text = 'Imported Playlist';
          _phase = _ImportPhase.preview;
          _isProcessing = false;
        });
      } else {
        // URL requires backend parsing
        final result = await PlaylistImportService.parsePlaylist(
          type: type,
          content: content,
        );

        if (result.hasError || result.items.isEmpty) {
          setState(() {
            _errorMessage = result.error ?? 'No songs found at this URL. Try pasting the playlist as text instead.';
            _isProcessing = false;
          });
          return;
        }

        setState(() {
          _previewItems = result.items;
          _nameController.text =
              result.name.isNotEmpty ? result.name : 'Imported Playlist';
          _phase = _ImportPhase.preview;
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to parse playlist: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _handleImport() async {
    final content = _tabController.index == 0
        ? _textController.text
        : _urlController.text;
    final type = _tabController.index == 0 ? 'text' : 'url';
    final preferences = context.read<PreferencesProvider>();

    setState(() {
      _phase = _ImportPhase.importing;
      _progress = 0;
      _isProcessing = true;
    });

    final result = await PlaylistImportService.importPlaylist(
      type: type,
      content: content,
      playlistName: _nameController.text.trim().isNotEmpty
          ? _nameController.text.trim()
          : null,
      preferredLanguages: preferences.languages.toList(),
      onProgress: (p) {
        if (mounted) {
          setState(() => _progress = p);
        }
      },
    );

    if (mounted) {
      setState(() {
        _result = result;
        _phase = _ImportPhase.results;
        _isProcessing = false;
      });
    }
  }

  Future<void> _handleCreatePlaylist(PlaylistImportResult result) async {
    if (result.matched.isEmpty) return;

    final playlistProvider =
        Provider.of<PlaylistProvider>(context, listen: false);

    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : result.playlistName;

    try {
      if (widget.targetPlaylistId != null) {
        // Add to existing playlist
        await playlistProvider.addSongsToPlaylist(
          widget.targetPlaylistId!,
          result.matched.map((m) => m.song).toList(),
        );
      } else {
        // Create new playlist with all matched songs at once
        await playlistProvider.createPlaylist(
          name,
          initialSongs: result.matched.map((m) => m.song).toList(),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✨ Playlist "$name" created with ${result.matched.length} songs!',
            ),
            backgroundColor: AppTheme.accentPurple,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create playlist: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}

enum _ImportPhase {
  input,
  preview,
  importing,
  results,
}
