# StikDebug Rutas 2

Actualización del 6 de noviembre de 2026 sobre StikDebug 3.1.15. Se conserva AGPL-3.0.
Repositorio: https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/tree/route-speed-repeat

## Funciones

- Rutas a pie/carro, velocidad automática o personalizada entre 0,5 y 200 km/h.
- Hasta cinco paradas intermedias, además de origen y destino. Orden editable, búsqueda por dirección/coordenadas o mapa y espera independiente de 0 a 86.400 segundos por punto.
- Se calcula cada tramo entre puntos. Si Apple Maps no alcanza un punto a menos de 30 metros, se exige corregirlo; no se salta silenciosamente. Los extremos ajustados a carriles próximos se conectan con segmentos cortos.
- Repetición de ida/vuelta. Las paradas y tiempos se repiten en orden inverso al regresar. En carro se calcula un regreso independiente a través de esas paradas; a pie se invierte la geometría. Las rutas importadas mantienen sus coordenadas.
- Pausa/reanudar también congela la cuenta regresiva. Stop cancela inmediatamente tareas, esperas y envíos locales. La confirmación de restauración del GPS del dispositivo se muestra por separado.
- Estado de conexión, última actualización confirmada, diagnóstico técnico y reintento manual acotado. Una ruta reconectada queda pausada hasta pulsar Resume.
- Movimiento interpolado a partir de geometría, sin almacenar un punto por cada medio segundo. Límite de 100.000 vértices y archivos importados de 20 MB.
- Aceleración y frenada gradual en carro, reducción en curvas, velocidad actual, progreso, vueltas completas y tiempo restante aproximado con esperas.
- Límites OSM elegidos según orientación y continuidad de vía; se respetan etiquetas forward/backward. Semáforos simulados por visita al cruce, incluso en rutas que lo atraviesan varias veces.
- Paradas aleatorias en el 60% de visitas a señales OSM, de 5 segundos al máximo configurado (hasta 90). No se conoce el color real. Si coinciden con una parada programada, se usa la espera mayor y no se suman.
- Tráfico Apple: suma ETA de los tramos y la compara con sus tiempos ideales. Reducción aproximada para el recorrido completo; no estima velocidad por calle. Consulta al inicio de cada ida/vuelta, 10 segundos máximos por tramo. Se descarta la estimación completa si falta un tramo o la distancia difiere más del 5%. No se usa para rutas importadas/alternativas.
- Búsqueda escrita con elección explícita de resultados, coordenadas y selección en mapa. La cobertura depende de Apple Maps.
- Se restauran las preparaciones interrumpidas al salir y volver a la vista. Opciones de movimiento persistentes.
- Puerto Bonjour solo se utiliza si la IP anunciada coincide con el destino; emparejamiento autentica la conexión.
- Versión visible con número de compilación, revisión y fecha UTC.
- Enlace Waze abre solo el destino. No importa sus rutas/tráfico. Google Maps no está integrado ni se activó facturación.

## Datos móviles

El usuario confirmó simulación siguiendo esta secuencia: conectar LocalDevVPN con datos activos, apagar temporalmente SOLO Datos móviles conservando la VPN, establecer simulación en StikDebug y reactivar datos tras conectar. No se garantiza reconexión tras reinicio o suspensión de iOS. Error 3 corresponde al túnel; por sí solo no demuestra ausencia del DDI.

## Validación

La revisión anterior instalada fue 8fc79789a9b9bc2d563b7c601045c3548f8662bd, compilada correctamente:
https://github.com/uyasanrodrigo-sudo/StikDebug-Rutas/actions/runs/41133038303

Esta actualización requiere su propia ejecución Swift y archivo Xcode en GitHub Actions. La comprobación de sintaxis local no sustituye compilación ni pruebas físicas. El resultado de la ejecución y el IPA se registran aparte en validacion-mejoras-rutas.json.

```sh
swiftc -D ROUTE_SESSION_CHECKS StikDebug/Services/RoutePlaybackOptions.swift StikDebug/Services/LocationSimulationSession.swift RoutePlaybackTimingChecks.swift -o /tmp/route-checks
/tmp/route-checks
```

Las comprobaciones ejecutan geometría, aceleración/frenada, señales repetidas, espera programada y retorno, pausa del contador, Stop de la sesión real, reconexión pausada, fallo del temporizador y rechazo de envíos pendientes. GitHub Actions también compila la app completa para iPhone y empaqueta metadatos únicos.

## Pruebas físicas después de instalar

1. Ruta de cinco paradas: comprobar orden y esperas distintas (por ejemplo 10, 20, 30, 40 y 50 s), editar, reordenar y eliminar. No debe poder añadirse una sexta parada.
2. Pausar a mitad de una espera, reanudar y comprobar que no se descuenta tiempo durante pausa.
3. Repetir: verificar las cinco paradas en orden inverso, tiempos y segunda vuelta sin saltos.
4. Desconectar VPN caminando y durante una parada; verificar estado perdido, último punto, reintento y reanudación manual.
5. Stop durante movimiento, espera y fallo de conexión. No deben salir nuevos puntos; revisar confirmación de GPS.
6. Cambiar de vista durante preparación y durante ruta; verificar recuperación y progreso.
7. Probar direcciones ambiguas, coordenadas, punto en mapa, GPX, datos móviles, segundo plano y pantalla bloqueada.

Segundo plano y continuidad en red celular requieren verificación real en el iPhone; Xcode no los certifica.
