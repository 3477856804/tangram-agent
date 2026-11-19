import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 百度地图 WebView（使用原工程 AK）。
///
/// - Android/iOS：加载百度 JS API，真实街道底图 + 轨迹/标记/点击选点；
/// - 其它平台：不支持 WebView 的百度 JS，页面会回退 OSM。
///
/// 坐标沿用原工程：默认点位与轨迹都按百度坐标系（BD-09）处理，
/// 不做 WGS84→BD09 二次转换，避免和原版偏移。
class BaiduMapView extends StatefulWidget {
  const BaiduMapView({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.route,
    required this.current,
    required this.onTap,
  });

  static const String ak = 'P9I4SjSfRtFenM1hLTyZwoW3YLnmtSda';

  static bool get supported =>
      Platform.isAndroid || Platform.isIOS;

  final double startLat;
  final double startLng;
  final List<Map<String, dynamic>> route;
  final Map<String, dynamic> current;
  final void Function(double lat, double lng) onTap;

  @override
  State<BaiduMapView> createState() => _BaiduMapViewState();
}

class _BaiduMapViewState extends State<BaiduMapView> {
  late final WebViewController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF2F4F8))
      ..addJavaScriptChannel(
        'BaiduMapTap',
        onMessageReceived: (JavaScriptMessage message) {
          _handleTap(message.message);
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (String url) {
          _ready = true;
          _sync();
          Future<void>.delayed(const Duration(milliseconds: 800), _sync);
        },
      ))
      ..loadHtmlString(_html(), baseUrl: 'https://api.map.baidu.com');
  }

  @override
  void didUpdateWidget(covariant BaiduMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _handleTap(String raw) {
    try {
      final Object? data = jsonDecode(raw);
      if (data is Map) {
        final double lat = (data['lat'] as num?)?.toDouble() ?? 0;
        final double lng = (data['lng'] as num?)?.toDouble() ?? 0;
        if (lat != 0 && lng != 0) widget.onTap(lat, lng);
      }
    } on Object {
      // 非法消息忽略，不影响地图。
    }
  }

  void _sync() {
    if (!_ready) return;
    final String routeJson = jsonEncode(widget.route);
    final String currentJson = jsonEncode(widget.current);
    _controller.runJavaScript(
      'setTgaData($routeJson, ${widget.startLat}, ${widget.startLng}, $currentJson);',
    );
  }

  String _html() {
    final String routeJson = jsonEncode(widget.route);
    final String currentJson = jsonEncode(widget.current);
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
  html,body,#map{width:100%;height:100%;margin:0;padding:0;overflow:hidden;background:#eef2f7}
  .bubble{position:absolute;left:10px;top:10px;z-index:999;background:rgba(255,255,255,.92);
    color:#5b6472;font:12px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
    padding:5px 9px;border-radius:999px;box-shadow:0 2px 8px rgba(0,0,0,.08)}
</style>
<script src="https://api.map.baidu.com/api?v=3.0&ak=${BaiduMapView.ak}"></script>
</head>
<body>
<div class="bubble">点击地图设起点</div>
<div id="map"></div>
<script>
var map, routeLine, markers = [];
function initMap(){
  map = new BMap.Map("map", {enableMapClick:false});
  var center = new BMap.Point(${widget.startLng}, ${widget.startLat});
  map.centerAndZoom(center, 16);
  map.enableScrollWheelZoom(true);
  map.enableDragging();
  map.enableInertialDragging();
  map.enablePinchToZoom(true);
  map.addEventListener("click", function(e){
    if (window.BaiduMapTap) {
      window.BaiduMapTap.postMessage(JSON.stringify({lat:e.point.lat,lng:e.point.lng}));
    }
  });
  setTgaData($routeJson, ${widget.startLat}, ${widget.startLng}, $currentJson);
}
function clearOverlays(){
  if (routeLine) { map.removeOverlay(routeLine); routeLine = null; }
  for (var i=0;i<markers.length;i++){ map.removeOverlay(markers[i]); }
  markers = [];
}
function addMarker(lat,lng,color,label){
  var p = new BMap.Point(lng,lat);
  var m = new BMap.Marker(p);
  map.addOverlay(m);
  markers.push(m);
  if (label) {
    var lbl = new BMap.Label(label,{offset:new BMap.Size(20,-10)});
    m.setLabel(lbl);
  }
}
function setTgaData(route, startLat, startLng, current){
  if (!map) return;
  clearOverlays();
  var pts = [];
  for (var i=0;i<route.length;i++){
    pts.push(new BMap.Point(route[i].lng, route[i].lat));
  }
  if (pts.length > 1){
    routeLine = new BMap.Polyline(pts,{strokeColor:"#4C6FFF",strokeWeight:5,strokeOpacity:.9});
    map.addOverlay(routeLine);
    addMarker(route[0].lat, route[0].lng, "#21C06B", "起");
    addMarker(route[route.length-1].lat, route[route.length-1].lng, "#FF5A5F", "终");
  }
  if (current && current.lat && current.lng){
    addMarker(current.lat, current.lng, "#4C6FFF", "我");
  } else if (startLat && startLng) {
    addMarker(startLat, startLng, "#4C6FFF", "我");
  }
}
function zoomBy(delta){
  if (!map) return;
  map.setZoom(map.getZoom() + delta);
}
function recenter(lat,lng){
  if (!map) return;
  map.panTo(new BMap.Point(lng,lat));
}
if (window.BMap) { initMap(); }
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        WebViewWidget(
          controller: _controller,
          // 地图在 ListView 里：必须让 WebView 赢得手势竞技场，
          // 否则上下滑动会被外层列表抢走，表现为“地图拖不动/点不了”。
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
        Positioned(
          right: 10,
          top: 10,
          child: Column(
            children: <Widget>[
              _button(Icons.add_rounded, () {
                _controller.runJavaScript('zoomBy(1);');
              }),
              const SizedBox(height: 8),
              _button(Icons.remove_rounded, () {
                _controller.runJavaScript('zoomBy(-1);');
              }),
              const SizedBox(height: 8),
              _button(Icons.my_location_rounded, () {
                _controller.runJavaScript(
                    'recenter(${widget.startLat},${widget.startLng});');
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white.withValues(alpha: 0.95),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 20, color: const Color(0xFF4C6FFF)),
          ),
        ),
      );
}
