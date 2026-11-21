// The browser gets the real video layer; everything else gets an empty one.
export 'login_video_stub.dart' if (dart.library.html) 'login_video_web.dart';
