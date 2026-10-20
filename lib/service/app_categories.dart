enum AppCategory { social, videoMusic, messaging, games, other }

extension AppCategoryLabel on AppCategory {
  String get label {
    switch (this) {
      case AppCategory.social:
        return 'Social media';
      case AppCategory.videoMusic:
        return 'Video & music';
      case AppCategory.messaging:
        return 'Messaging';
      case AppCategory.games:
        return 'Games';
      case AppCategory.other:
        return 'Other';
    }
  }
}

// Built-in list of common apps by package name. Anything not listed falls
// back to Android's own app category, then to "Other".
const Map<String, AppCategory> _known = {
  // Social media
  'com.instagram.android': AppCategory.social,
  'com.instagram.barcelona': AppCategory.social,
  'com.facebook.katana': AppCategory.social,
  'com.facebook.lite': AppCategory.social,
  'com.twitter.android': AppCategory.social,
  'com.snapchat.android': AppCategory.social,
  'com.zhiliaoapp.musically': AppCategory.social,
  'com.ss.android.ugc.trill': AppCategory.social,
  'com.pinterest': AppCategory.social,
  'com.reddit.frontpage': AppCategory.social,
  'com.linkedin.android': AppCategory.social,
  'com.tumblr': AppCategory.social,
  'in.mohalla.sharechat': AppCategory.social,
  'in.mohalla.video': AppCategory.social,
  // Video & music
  'com.google.android.youtube': AppCategory.videoMusic,
  'com.google.android.apps.youtube.music': AppCategory.videoMusic,
  'com.netflix.mediaclient': AppCategory.videoMusic,
  'com.amazon.avod.thirdpartyclient': AppCategory.videoMusic,
  'in.startv.hotstar': AppCategory.videoMusic,
  'com.spotify.music': AppCategory.videoMusic,
  'com.jio.media.jiobeats': AppCategory.videoMusic,
  'com.gaana': AppCategory.videoMusic,
  'com.mxtech.videoplayer.ad': AppCategory.videoMusic,
  // Messaging
  'com.whatsapp': AppCategory.messaging,
  'com.whatsapp.w4b': AppCategory.messaging,
  'org.telegram.messenger': AppCategory.messaging,
  'org.thoughtcrime.securesms': AppCategory.messaging,
  'com.discord': AppCategory.messaging,
  'com.facebook.orca': AppCategory.messaging,
  'com.google.android.apps.messaging': AppCategory.messaging,
  // Games
  'com.supercell.clashofclans': AppCategory.games,
  'com.activision.callofduty.shooter': AppCategory.games,
  'com.tencent.ig': AppCategory.games,
  'com.dts.freefireth': AppCategory.games,
  'com.dts.freefiremax': AppCategory.games,
  'com.king.candycrushsaga': AppCategory.games,
  'com.kiloo.subwaysurf': AppCategory.games,
  'com.roblox.client': AppCategory.games,
  'com.mojang.minecraftpe': AppCategory.games,
};

AppCategory categoryFor(String package, int androidCategory) {
  final k = _known[package];
  if (k != null) return k;
  switch (androidCategory) {
    case 4: // CATEGORY_SOCIAL
      return AppCategory.social;
    case 1: // CATEGORY_AUDIO
    case 2: // CATEGORY_VIDEO
      return AppCategory.videoMusic;
    case 0: // CATEGORY_GAME
      return AppCategory.games;
    default:
      return AppCategory.other;
  }
}