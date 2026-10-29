# StikDebug: rutas personalizadas

Copia local de StikDebug 3.1.15, commit base `3422fc4725cd9d1fbc255ea36c6fe06eecfdf459`.
Rama local: `route-speed-repeat`. Conserva la licencia AGPL-3.0 del proyecto original.

## Cambios

- Modo a pie o en carro: solicita las indicaciones correspondientes a Apple Maps.
- Velocidad automática: 5 km/h a pie; límites de carretera o estimación de Apple Maps en carro.
- Velocidad personalizada de 0,5 a 200 km/h, con accesos a 5, 15 y 50 km/h.
- Repetición continua de ida y vuelta por la misma geometría, sin saltar del destino al origen. Se detiene con Stop.
- Selección de rutas alternativas cuando Apple Maps las devuelve.
- Recalcular solicita nuevas indicaciones; vista de mapa estándar o satélite.
- Las rutas importadas mantienen sus coordenadas, sin recalcularlas al cambiar el modo.
- Caminar y velocidad personalizada omiten la consulta de velocidades de OpenStreetMap. La consulta en modo carro tiene un tiempo de espera de 20 segundos y usa una estimación si falla.
- Las opciones de movimiento se cambian antes de iniciar; para modificarlas durante una simulación, detener primero.

## Estado de validación

En Windows se revisaron la sintaxis Swift con tree-sitter y el formato del workflow YAML.
No hay Xcode ni compilador Swift instalado: **no se ha compilado esta app, ejecutado los tests Swift ni instalado la versión modificada en el iPhone**.
El archivo `.ipa` oficial que se instaló previamente no incluye estos cambios.

El test independiente `RoutePlaybackTimingChecks.swift` comprueba conversión de velocidad, límites, entradas no finitas, tiempo de regreso, continuidad entre ciclos y recorridos vacíos/cortos.

## Compilar en macOS o GitHub Actions

En una Mac con Xcode 26 o posterior, abrir `StikDebug.xcodeproj` y compilar el esquema StikDebug.
Para ejecutar los tests independientes desde la carpeta del proyecto:

```sh
swiftc StikDebug/Services/RoutePlaybackOptions.swift RoutePlaybackTimingChecks.swift -o /tmp/route-checks
/tmp/route-checks
```

Para compilar sin tener una Mac propia, subir esta copia a un repositorio propio de GitHub y ejecutar manualmente el workflow **Build custom routes IPA**. Se incluye en `.github/workflows/custom_routes.yml`.
Ese workflow ejecuta los tests anteriores, compila la app y adjunta `StikDebug-CustomRoutes.ipa` como artefacto. No publica releases ni envía cambios al repositorio original.
No se ha subido esta copia a GitHub ni ejecutado un workflow remoto.
El artefacto requiere firma mediante iLoader/SideStore antes de usarlo en el iPhone.

## Comprobaciones pendientes en iPhone

1. Pedir una ruta corta a pie y en carro: comprobar que cambian los caminos cuando corresponde.
2. Probar 5 y 15 km/h en el mismo recorrido y comparar tiempos aproximados.
3. Activar Repeat round trip: comprobar llegada, regreso y segundo ciclo sin salto al inicio.
4. Detener durante ida y regreso; comprobar que no vuelven a enviarse puntos del recorrido.
5. Cambiar ruta alternativa y pulsar Recalculate antes de reproducir.
6. Probar un GPX importado y verificar que conserva su trazado.
7. Probar segundo plano, pantalla bloqueada y datos móviles por separado.

La cobertura de mapas y rutas depende de Apple Maps y la conexión. Recalcular no añade caminos que el proveedor no conozca.
La repetición inversa simula coordenadas; no calcula un regreso distinto para respetar sentidos únicos de calles.
Las restricciones de iOS sobre segundo plano y conexiones móviles siguen requiriendo pruebas reales.
