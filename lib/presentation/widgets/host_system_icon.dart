import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';

class HostSystemIcon extends StatelessWidget {
  const HostSystemIcon({
    super.key,
    required this.host,
    this.size = 44,
    this.systemInfo,
  });

  final HostProfile host;
  final double size;
  final ServerSystemInfo? systemInfo;

  @override
  Widget build(BuildContext context) {
    final distro = normalizeDistroId(systemInfo?.distro ?? host.distro);
    final color = _brandColors[distro] ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label:
          '${systemInfo?.prettyName ?? host.systemInfo?.prettyName ?? distro} 系统',
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(size * 0.27),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: SvgPicture.asset(
          'assets/distro/$distro.svg',
          fit: BoxFit.contain,
          placeholderBuilder: (_) => Icon(
            Icons.dns_outlined,
            size: size * 0.55,
            color: color,
          ),
        ),
      ),
    );
  }
}

const _brandColors = <String, Color>{
  'ubuntu': Color(0xffe95420),
  'debian': Color(0xffa80030),
  'centos': Color(0xff932279),
  'rocky': Color(0xff10b981),
  'fedora': Color(0xff51a2da),
  'redhat': Color(0xffee0000),
  'almalinux': Color(0xff0f4266),
  'arch': Color(0xff1793d1),
  'alpine': Color(0xff0d597f),
  'amazon': Color(0xffff9900),
  'opensuse': Color(0xff73ba25),
  'oracle': Color(0xfff80000),
  'kali': Color(0xff557c94),
  'alinux': Color(0xffff6a00),
  'openeuler': Color(0xff002fa7),
  'macos': Color(0xffa2aaad),
  'freebsd': Color(0xffab2b28),
  'windows': Color(0xff0078d4),
  'linux': Color(0xfff2c94c),
  'cisco': Color(0xff1ba0d7),
  'juniper': Color(0xff84b135),
  'huawei': Color(0xffcf0a2c),
  'h3c': Color(0xffe60012),
  'hpe': Color(0xff01a982),
  'mikrotik': Color(0xff293239),
  'fortinet': Color(0xffee3124),
  'paloalto': Color(0xfff04e23),
  'zyxel': Color(0xfff39800),
};
