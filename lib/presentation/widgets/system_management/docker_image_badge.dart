import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

class DockerImageBadge extends StatelessWidget {
  const DockerImageBadge({super.key, required this.imageName});

  final String imageName;

  @override
  Widget build(BuildContext context) {
    final brand = _dockerBrand(imageName);
    return Tooltip(
      message: brand.name,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: brand.color,
          borderRadius: BorderRadius.circular(11),
        ),
        child: brand.asset == null
            ? LText(
                brand.mark,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: brand.mark.length > 2 ? 10 : 14,
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(9),
                child: SvgPicture.asset(brand.asset!),
              ),
      ),
    );
  }
}

class _DockerBrand {
  const _DockerBrand(this.name, this.mark, this.color, {this.asset});

  final String name;
  final String mark;
  final Color color;
  final String? asset;
}

_DockerBrand _dockerBrand(String value) {
  final name = value.toLowerCase();
  const rules = <(String, _DockerBrand)>[
    (
      'nginx',
      _DockerBrand(
        'nginx',
        'N',
        Color(0xFF009639),
        asset: 'assets/docker/nginx.svg',
      ),
    ),
    (
      'redis',
      _DockerBrand(
        'Redis',
        'R',
        Color(0xFFDC382D),
        asset: 'assets/docker/redis.svg',
      ),
    ),
    ('valkey', _DockerBrand('Valkey', 'V', Color(0xFFA41E34))),
    (
      'postgres',
      _DockerBrand(
        'PostgreSQL',
        'PG',
        Color(0xFF4169E1),
        asset: 'assets/docker/postgresql.svg',
      ),
    ),
    ('mariadb', _DockerBrand('MariaDB', 'M', Color(0xFF003545))),
    ('mysql', _DockerBrand('MySQL', 'My', Color(0xFF4479A1))),
    ('mongo', _DockerBrand('MongoDB', 'M', Color(0xFF47A248))),
    ('rabbitmq', _DockerBrand('RabbitMQ', 'RMQ', Color(0xFFFF6600))),
    ('kafka', _DockerBrand('Kafka', 'K', Color(0xFF231F20))),
    ('elasticsearch', _DockerBrand('Elasticsearch', 'ES', Color(0xFF005571))),
    ('opensearch', _DockerBrand('OpenSearch', 'OS', Color(0xFF005EB8))),
    ('grafana', _DockerBrand('Grafana', 'G', Color(0xFFF46800))),
    ('prometheus', _DockerBrand('Prometheus', 'P', Color(0xFFE6522C))),
    ('node', _DockerBrand('Node.js', 'JS', Color(0xFF339933))),
    ('python', _DockerBrand('Python', 'Py', Color(0xFF3776AB))),
    ('golang', _DockerBrand('Go', 'Go', Color(0xFF00ADD8))),
    ('openjdk', _DockerBrand('OpenJDK', 'J', Color(0xFF437291))),
    ('wordpress', _DockerBrand('WordPress', 'W', Color(0xFF21759B))),
    ('alpine', _DockerBrand('Alpine', 'A', Color(0xFF0D597F))),
    ('ubuntu', _DockerBrand('Ubuntu', 'U', Color(0xFFE95420))),
    ('debian', _DockerBrand('Debian', 'D', Color(0xFFA81D33))),
  ];
  for (final rule in rules) {
    if (name.contains(rule.$1)) return rule.$2;
  }
  return const _DockerBrand(
    'Docker image',
    '◆',
    Color(0xFF2496ED),
    asset: 'assets/docker/container.svg',
  );
}
