# StikDebug: rutas personalizadas

Copia local de StikDebug 3.1.15, commit base `3422fc4725cd9d1fbc255ea36c6fe06eecfdf459`.
Rama local: `route-speed-repeat`. Conserva la licencia AGPL-3.0 del proyecto original.

El fork remoto parte de main `17b1e1d90d602a228de663a10efa987a9f9e547b`; la vista del simulador coincide con 3.1.15. Se incorporó el descubrimiento de puerto de ese main a la copia local.

## Cambios

- Modo a pie o en carro: solicita las indicaciones correspondientes a Apple Maps.
- Velocidad automática: 5 km/h a pie; límites de carretera o estimación de Apple Maps en carro.
- Velocidad personalizada de 0,5 a 200 km/h, con accesos a 5, 15 y 50 km/h.
- Repetición continua: en carro calcula un regreso independiente con Apple Maps; a pie y en rutas importadas recorre la geometría en sentido inverso. Se detiene con Stop.
- Selección de rutas alternativas cuando Apple Maps las devuelve.
- Recalcular solicita nuevas indicaciones; vista de mapa estándar o satélite.
- Las rutas importadas mantienen sus coordenadas, sin recalcularlas al cambiar el modo.
- Caminar y velocidad personalizada omiten la consulta de velocidades de OpenStreetMap. La consulta en modo carro tiene un tiempo de espera de 20 segundos y usa una estimación si falla.
- Las opciones de movimiento se cambian antes de iniciar; para modificarlas durante una simulación, detener primero.
- En carro, paradas simuladas cerca de semáforos registrados en OpenStreetMap: 60% de probabilidad por paso y de 5 a 45 segundos por defecto, máximo configurable hasta 90 segundos. No se conoce el color real; los cruces con varios nodos próximos se agrupan.
- Tráfico: compara calculateETA (con tráfico previsto) con el tiempo ideal de la ruta. Aplica una reducción aproximada para el recorrido completo, consultada al inicio de cada tramo de ida o vuelta. No inventa velocidades por calle; si la distancia estimada difiere más del 5%, la ruta es importada/alternativa, o la consulta falla, conserva la velocidad seleccionada. Cada consulta tiene un límite de espera de 15 segundos.
- Conexión: intenta reutilizar el túnel que la app ya estableció, mantiene vivos sus identificadores durante la sesión y usa descubrimiento de puerto en la conexión nueva. El error 3 identifica creación del túnel; ahora muestra el detalle real en lugar de atribuirlo genéricamente al DDI.
- El usuario confirmó una sesión funcional con datos móviles tras conectar LocalDevVPN, apagar temporalmente solo los datos, establecer la sesión y volver a activarlos. La guía aparece en opciones; no garantiza reconexión tras reinicio o cierre de la app.

## Estado de validación

La compilación anterior 472e6f7 pasó pruebas Swift y Xcode en GitHub Actions:
https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/actions/runs/40890999015 .
Se instaló con iLoader el 30 de octubre de 2026. Primero falló abrir el túnel en 4G;
posteriormente el usuario confirmó simulación con datos siguiendo la secuencia indicada abajo.

La nueva revisión añade cancelación de envíos pendientes, reloj monótono para compensar latencia,
regreso independiente en carro, búsqueda directa y elección de puntos en el mapa,
y un enlace para abrir el destino en Waze. Tiene revisión de sintaxis local; **pendiente de
compilación Swift/Xcode y de validación física en iPhone**. El IPA existente corresponde a 472e6f7.

Los tests independientes comprueban velocidad y ciclos, compensación de latencia,
rechazo de envíos obsoletos en cola, direcciones que no deben interpretarse como coordenadas
y parámetros del enlace Waze.

## Compilar en macOS o GitHub Actions

En una Mac con Xcode 26 o posterior, abrir `StikDebug.xcodeproj` y compilar el esquema StikDebug.
Para ejecutar los tests independientes desde la carpeta del proyecto:

```sh
swiftc StikDebug/Services/RoutePlaybackOptions.swift RoutePlaybackTimingChecks.swift -o /tmp/route-checks
/tmp/route-checks
```

Para compilar sin tener una Mac propia, subir esta copia a un repositorio propio de GitHub y ejecutar manualmente el workflow **Build custom routes IPA**. Se incluye en `.github/workflows/custom_routes.yml`.
Ese workflow ejecuta los tests anteriores, compila la app y adjunta `StikDebug-CustomRoutes.ipa` como artefacto. No publica releases ni envía cambios al repositorio original.
Repositorio remoto: https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/tree/route-speed-repeat . La primera compilación (sin tráfico ni reutilización del túnel) terminó correctamente y pasó las pruebas de velocidad y ciclos: https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/actions/runs/40887135833 . La nueva revisión requiere su propia compilación y prueba física.
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
El regreso independiente en carro usa las indicaciones de Apple Maps. Se rechazan huecos mayores de 30 metros entre extremos; los puntos ajustados por Apple a carriles cercanos se enlazan con conexiones cortas. Las rutas importadas conservan sus coordenadas, aunque se elija carro.
Las restricciones de iOS sobre segundo plano y conexiones móviles siguen requiriendo pruebas reales.


## Conexión con datos — 30 de octubre de 2026

LocalDevVPN reconoce una limitación al crear sesiones en red celular:
https://github.com/jkcoxson/LocalDevVPN/issues/31 . Otra implementación documenta
la secuencia en https://github.com/seanhowarthdev/Roam-Control/blob/main/Documentation/UserGuide.md#mobile-data-connection-flow .
El usuario confirmó que pudo cambiar y simular con datos móviles después de probar:

1. Con datos encendidos, conectar LocalDevVPN.
2. Apagar temporalmente solo Datos móviles, conservando la VPN.
3. Establecer la conexión/simulación en StikDebug.
4. Reactivar Datos móviles tras conectar correctamente.

No se ha verificado persistencia después de reinicio, reconexión ni pantalla bloqueada.

## Búsqueda de direcciones

La app consulta Apple Maps; no tiene una lista pequeña de direcciones guardadas.
El problema anterior era exigir una sugerencia y no buscar el texto al pulsar Enter.
Ahora se puede buscar la dirección completa con ciudad/país, elegir uno de los resultados,
escribir una pareja exacta latitud,longitud o seleccionar origen/destino en el mapa.
Los errores de búsqueda explican estas alternativas. Los resultados tardíos se descartan si
se edita el texto. La existencia de una dirección no garantiza cobertura de rutas del proveedor.
La búsqueda principal muestra hasta 10 sugerencias; el formulario de rutas muestra las recibidas.

## Waze y posible migración a Google Maps

El enlace Waze usa la API oficial de enlaces:
https://developers.google.com/waze/deeplinks . Abre el destino solo al pulsarlo; Waze calcula
su propio recorrido. No importa rutas, tráfico ni estado de semáforos de Waze.

Google Maps se está evaluando como una ampliación independiente. No está integrado ni se ha
activado facturación. Requiere un proyecto Cloud con facturación, claves restringidas y revisar
los cargos y condiciones de Maps SDK, Places y Routes. Los datos de rutas Google mostrados
sobre un mapa deben aparecer en Google Maps. Referencias:
- https://developers.google.com/maps/documentation/ios-sdk/get-api-key
- https://developers.google.com/maps/documentation/routes/policies
- https://developers.google.com/maps/billing-and-pricing/pricing
