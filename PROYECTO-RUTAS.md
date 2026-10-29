# StikDebug: rutas personalizadas

Copia local de StikDebug 3.1.15, commit base `3422fc4725cd9d1fbc255ea36c6fe06eecfdf459`.
Rama local: `route-speed-repeat`. Conserva la licencia AGPL-3.0 del proyecto original.

El fork remoto parte de main `17b1e1d90d602a228de663a10efa987a9f9e547b`; la vista del simulador coincide con 3.1.15. Se incorporó el descubrimiento de puerto de ese main a la copia local.

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
- En carro, paradas simuladas cerca de semáforos registrados en OpenStreetMap: 60% de probabilidad por paso y de 5 a 45 segundos por defecto, máximo configurable hasta 90 segundos. No se conoce el color real; los cruces con varios nodos próximos se agrupan.
- Tráfico: compara calculateETA (con tráfico previsto) con el tiempo ideal de la ruta. Aplica una reducción aproximada para el recorrido completo, consultada al inicio de cada tramo de ida o vuelta. No inventa velocidades por calle; si la distancia estimada difiere más del 5%, la ruta es importada/alternativa, o la consulta falla, conserva la velocidad seleccionada. Cada consulta tiene un límite de espera de 15 segundos.
- Conexión: intenta reutilizar el túnel que la app ya estableció, mantiene vivos sus identificadores durante la sesión y usa descubrimiento de puerto en la conexión nueva. El error 3 identifica creación del túnel; ahora muestra el detalle real en lugar de atribuirlo genéricamente al DDI.
- El funcionamiento con datos móviles sigue pendiente de probar en esta versión modificada. No se garantiza que iOS permita abrir un túnel nuevo sin Wi-Fi.

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
Repositorio remoto: https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/tree/route-speed-repeat . La primera compilación (sin tráfico ni reutilización del túnel) terminó correctamente y pasó las pruebas de velocidad y ciclos: https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/actions/runs/40887135833 . Las mejoras posteriores requieren una nueva compilación y prueba física.
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
