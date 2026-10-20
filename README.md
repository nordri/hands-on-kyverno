# Kyverno hands-on — Kubernetes admission policies

Laboratorio práctico de **Kyverno 1.19.1** sobre Kubernetes **1.35.x**, con políticas CEL modernas (`ValidatingPolicy` y `MutatingPolicy`). Objetivo: instalar Kyverno, aplicar controles de plataforma y comprobar sus efectos con comandos reproducibles.

> **Alcance real:** validación y mutación con CEL, `Audit`/`Deny`, `PolicyReports`, controles de imágenes, tests offline con Kyverno CLI y GitOps con Argo CD sobre Kind. Se comprobó detección de drift, sincronización manual, `selfHeal` y mutación de Pods gestionados por Argo CD. **Limitaciones conocidas:** los tests offline se ejecutaron sin `namespaceSelector` en una copia de la política; la protección del subrecurso `pods/ephemeralcontainers` quedó pendiente por un problema RBAC de reporting.

## 0. Requisitos

- Clúster Kubernetes accesible con `kubectl` (en el lab: Kubernetes 1.35.x, inicialmente KillerKoda; también se utilizó Kind).
- Helm instalado (en el lab: Helm 4.1.1).
- Permisos para instalar CRDs, webhooks y políticas de ámbito clúster.

```bash
kubectl cluster-info
kubectl get nodes
helm version
```

## 1. Instalar Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.9.1

kubectl get deploy -n kyverno
kubectl get pods -n kyverno
kubectl get crd | grep kyverno
```

**Esperado:** los cuatro deployments (`admission`, `background`, `cleanup`, `reports`) disponibles. En nuestro laboratorio se instaló Kyverno **1.19.1** con chart **3.9.1**.

Crear namespaces para diferenciar entornos:

```bash
kubectl create namespace development
kubectl create namespace production
kubectl label namespace development security-level=permissive
kubectl label namespace production security-level=restricted
kubectl get ns development production --show-labels
```

## 2. ValidatingPolicy: prohibir contenedores privilegiados

Guardar como `disallow-privileged.yaml`:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: disallow-privileged
spec:
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security-level: restricted
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c, !has(c.securityContext) ||
          !has(c.securityContext.privileged) || c.securityContext.privileged != true) &&
        (!has(object.spec.initContainers) || object.spec.initContainers.all(c,
          !has(c.securityContext) || !has(c.securityContext.privileged) ||
          c.securityContext.privileged != true)) &&
        (!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.all(c,
          !has(c.securityContext) || !has(c.securityContext.privileged) ||
          c.securityContext.privileged != true))
      message: "Privileged containers, initContainers and ephemeralContainers are not allowed"
  validationActions: [Deny]
```

```bash
kubectl apply -f disallow-privileged.yaml
kubectl get validatingpolicies
```

Crear `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: production
spec:
  containers:
    - name: nginx
      image: nginx:alpine
      securityContext:
        privileged: true
```

```bash
kubectl apply -f privileged-pod.yaml
# Esperado: DENIED por disallow-privileged

kubectl run normal-test -n production --image=nginx:alpine --restart=Never
# Esperado: creado

sed 's/namespace: production/namespace: development/; s/name: privileged-test/name: privileged-dev/' \
  privileged-pod.yaml | kubectl apply -f -
# Esperado: creado; development no lleva security-level=restricted
```

**Bypass detectado y corregido:** una primera versión de la expresión solo inspeccionaba `spec.containers`, permitiendo un `initContainer` privilegiado. La versión anterior también revisa `initContainers` y `ephemeralContainers` en la especificación del Pod. **Eso no implica** cubrir automáticamente el subrecurso de depuración; ver §7.

## 3. Deny vs Audit y PolicyReports

Cambiar temporalmente en `disallow-privileged.yaml`:

```yaml
  validationActions: [Audit]
```

```bash
kubectl apply -f disallow-privileged.yaml
kubectl apply -f privileged-pod.yaml
# En Audit, el Pod se admite, pero se registra el incumplimiento.

kubectl get policyreports -A
kubectl get clusterpolicyreports
kubectl get policyreports -n production -o yaml
kubectl describe validatingpolicy disallow-privileged
kubectl get events -A --sort-by=.lastTimestamp | grep -E 'PolicyViolation|kyverno'
```

**Esperado:** resultados `fail` en reportes y/o eventos `PolicyViolation` (el reporte puede tardar por el escaneo en segundo plano). En el laboratorio observamos eventos tanto de `kyverno-admission` como de `kyverno-scan`. Un Pod ya existente **no se elimina automáticamente** al volver a `Deny`.

Volver a:

```yaml
  validationActions: [Deny]
```

```bash
kubectl apply -f disallow-privileged.yaml
```

## 4. MutatingPolicy: añadir una etiqueta

Guardar como `add-managed-label.yaml`:

```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata:
  name: add-managed-label
spec:
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security-level: permissive
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            metadata: Object.metadata{
              labels: {"managed-by": "kyverno"}
            }
          }
```

```bash
kubectl apply -f add-managed-label.yaml
kubectl get mutatingpolicies
kubectl run mutation-test -n development --image=nginx:alpine --restart=Never
kubectl get pod mutation-test -n development --show-labels
# Esperado: managed-by=kyverno
```

**Sobrescritura:** con esta expresión incondicional, un Pod creado con `managed-by: developer` terminó con `managed-by: kyverno`.

Para convertirla en un **valor por defecto** y respetar etiquetas explícitas, sustituir la expresión por:

```yaml
        expression: >-
          Object{
            metadata: Object.metadata{
              labels: {
                "managed-by": has(object.metadata.labels) &&
                              "managed-by" in object.metadata.labels
                  ? object.metadata.labels["managed-by"]
                  : "kyverno"
              }
            }
          }
```

```bash
kubectl apply -f add-managed-label.yaml
# Recrear el Pod de prueba con metadata.labels.managed-by: developer
# Esperado: managed-by=developer
```

**CREATE vs UPDATE:** si `operations: ["CREATE"]`, un `kubectl label ... --overwrite` posterior no activa esta mutación. Con `operations: ["CREATE", "UPDATE"]` y expresión condicional, se respeta el valor solicitado. Con expresión incondicional, Kyverno vuelve a imponer `managed-by=kyverno` en la actualización.

**Conflictos:** dos `MutatingPolicy` escribiendo `managed-by` dieron como resultado `platform` en nuestras pruebas; cambiar el orden de creación o el nombre no alteró el resultado. **No inferir una precedencia garantizada**. Cuando cada política modificó una etiqueta distinta (`managed-by` y `policy-test`), ambas aparecieron en el Pod.

## 5. ValidatingPolicy: prohibir `latest` y tags implícitos

Guardar como `disallow-latest.yaml`:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: disallow-latest
spec:
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security-level: restricted
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        (
          object.spec.containers +
          (has(object.spec.initContainers) ? object.spec.initContainers : []) +
          (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
        ).all(c,
          !c.image.endsWith(":latest") &&
          (
            c.image.contains("@sha256:") ||
            c.image.substring(c.image.lastIndexOf("/") + 1).contains(":")
          )
        )
      message: "All container images must use an explicit non-latest tag or SHA256 digest"
  validationActions: [Deny]
```

```bash
kubectl apply -f disallow-latest.yaml
kubectl get validatingpolicy disallow-latest
```

Probar en `production`:

```bash
kubectl run nginx-versioned -n production --image=nginx:1.27 --restart=Never
# Admitido (si no hay todavía otra política de registry)

kubectl run nginx-latest -n production --image=nginx:latest --restart=Never
# Denegado

kubectl run nginx-implicit -n production --image=nginx --restart=Never
# Denegado: nginx implica latest

kubectl run nginx-registry-tagged -n production \
  --image=registry.example.com:5000/nginx:1.27 --restart=Never
# Admitido por la regla de tag; puede quedar en ImagePullBackOff

kubectl run nginx-registry-implicit -n production \
  --image=registry.example.com:5000/nginx --restart=Never
# Denegado: el puerto 5000 no es un tag
```

La primera versión de la regla solo usaba `!image.endsWith(":latest")` y **dejaba pasar `nginx`**. La expresión mejorada exige tag explícito o digest y contempla `initContainers`.

## 6. ValidatingPolicy: registro autorizado

Guardar como `allowed-registries.yaml`:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: allowed-registries
spec:
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security-level: restricted
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.startsWith("registry.company.internal/")) &&
        (!has(object.spec.initContainers) ||
          object.spec.initContainers.all(c,
            c.image.startsWith("registry.company.internal/"))) &&
        (!has(object.spec.ephemeralContainers) ||
          object.spec.ephemeralContainers.all(c,
            c.image.startsWith("registry.company.internal/")))
      message: "All container images must come from registry.company.internal"
  validationActions: [Deny]
```

```bash
kubectl apply -f allowed-registries.yaml
kubectl get validatingpolicies

kubectl run registry-denied -n production --image=nginx:1.27 --restart=Never
# Denegado por allowed-registries

kubectl run registry-allowed -n production \
  --image=registry.company.internal/nginx:1.27 --restart=Never
# Admitido; ImagePullBackOff es esperable si el registry es ficticio
```

**Bypass probado:** un Pod con contenedor principal del registry corporativo e `initContainer` `busybox:1.36` fue admitido cuando la regla solo inspeccionaba `containers`. Tras ampliar la expresión a `initContainers`, el intento fue rechazado.

Ejemplo `latest-init-test.yaml` para aislar la regla de tags (ambas imágenes usan el registry autorizado):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: latest-init-test
  namespace: production
spec:
  initContainers:
    - name: setup
      image: registry.company.internal/busybox:latest
      command: ["sh", "-c", "echo setup"]
  containers:
    - name: nginx
      image: registry.company.internal/nginx:1.27
```

```bash
kubectl apply -f latest-init-test.yaml
# Denegado por disallow-latest: el initContainer usa :latest
```

## 7. Hallazgo pendiente: `pods/ephemeralcontainers`

Con la política limitada a `resources: ["pods"]`, ejecutamos:

```bash
kubectl get pod nginx-versioned -n production \
  -o jsonpath='{.spec.containers[*].name}'; echo

kubectl debug -n production nginx-versioned \
  --image=registry.company.internal/busybox:latest \
  --target=nginx-versioned --container=debug-test

kubectl get pod nginx-versioned -n production \
  -o jsonpath='{range .spec.ephemeralContainers[*]}{.name}{" -> "}{.image}{"\n"}{end}'
```

**Observado:** se añadió `debug-test -> registry.company.internal/busybox:latest` pese a la restricción. La actualización se realiza mediante `pods/ephemeralcontainers`, un subrecurso distinto de `pods`.

Intentamos incluir esta regla adicional en **ambas** políticas:

```yaml
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["UPDATE"]
        resources: ["pods/ephemeralcontainers"]
```

**Resultado:** ambas políticas pasaron a `READY=false`; `kubectl describe validatingpolicy disallow-latest` mostró `RBACPermissionsGranted=False` por falta de permisos `get`, `list` y `watch` sobre `pods/ephemeralcontainers` para reporting. No completamos la solución. Retiramos esa regla para recuperar `READY=true`.

**TODO:** investigar el soporte correcto del subrecurso y la estrategia de reporting/RBAC antes de afirmar que esta vía está protegida. No conceder permisos indiscriminadamente para conseguir `READY=true`.

## 8. Diagnóstico rápido

```bash
# Estado de las políticas
kubectl get validatingpolicies
kubectl get mutatingpolicies
kubectl describe validatingpolicy disallow-latest

# Informes de cumplimiento
kubectl get policyreports -A
kubectl get policyreports -n production -o yaml

# Eventos de admisión y escaneo
kubectl get events -A --sort-by=.lastTimestamp | grep PolicyViolation

# Controladores
kubectl get deploy -n kyverno
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=100
kubectl logs -n kyverno deploy/kyverno-reports-controller --tail=100

# Estado de los Pods (admitido != ejecutándose)
kubectl get pods -n production
```

`ImagePullBackOff` / `ErrImagePull` ocurre **después** de la admisión. Un Pod creado antes de endurecer la política puede continuar ejecutándose; los reportes permiten detectar incumplimientos existentes, pero `Deny` no elimina automáticamente los Pods antiguos.

## 9. Tests offline con Kyverno CLI

Se instaló la **CLI Kyverno 1.19.1** y se preparó una suite en `tests/` para comprobar la lógica CEL de `disallow-latest` sin desplegar Pods en Kubernetes.

Estructura relevante:

```text
hands-on-kyverno/
├── disallow-latest.yaml
├── Makefile
├── tests/
│   ├── kyverno-test.yaml
│   ├── resources.yaml
│   └── disallow-latest-test.yaml
└── gitops/
    ├── application.yaml
    ├── policies/
    │   └── disallow-latest.yaml
    ├── workloads-application.yaml
    └── workloads/
        └── nginx.yaml
```

`tests/resources.yaml` contiene dos Pods en `production`: uno con imagen `registry.company.internal/nginx:1.27` y otro con `registry.company.internal/nginx:latest`. El fichero `tests/kyverno-test.yaml` declara el resultado esperado: permitir el primero y rechazar el segundo.

```bash
kyverno version
kyverno test tests --detailed-results
make test
```

**Resultado observado:** `2 tests passed and 0 tests failed`, con `REASON: Ok` para ambos casos. El segundo test pasa porque **se espera un rechazo**; no significa que se haya permitido `:latest`.

**Limitación importante:** usando directamente `disallow-latest.yaml`, la CLI mostró `REASON: Excluded` para ambos Pods, incluso al añadir un recurso Namespace etiquetado al conjunto de recursos. Esto producía falsos verdes. Para probar la expresión CEL, se creó `tests/disallow-latest-test.yaml` sin `namespaceSelector`; con esa copia se obtuvo `REASON: Ok`.

Por tanto, la suite **prueba la lógica de validación, pero no reproduce completamente el alcance por namespace** de la política original. Mantener la copia sincronizada con la política de producción o generar la variante de test automáticamente para evitar divergencias. El comportamiento real del selector se comprobó en Kubernetes.

## 10. GitOps: Kyverno + Argo CD

### Entorno y despliegue

Se utilizó el clúster `kind-kyverno-lab` con Kubernetes **v1.35.0** y Kyverno operativo. El repositorio público es [nordri/hands-on-kyverno](https://github.com/nordri/hands-on-kyverno).

Argo CD se instaló en `argocd`. La instalación inicial mediante `kubectl apply` falló al crear el CRD `applicationsets.argoproj.io` por superar el límite de 262144 bytes de `metadata.annotations` (anotación de *client-side apply*). Se completó con *server-side apply*:

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pod --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

> En un entorno real, **fijar la versión** de Argo CD en lugar de usar `stable`. `--force-conflicts` fue aceptable en este clúster de laboratorio, pero no debe aplicarse indiscriminadamente en producción.

Acceso a la UI:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
# https://localhost:8080
# Usuario inicial: admin
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Application para políticas

`gitops/application.yaml` define `kyverno-policies`, apuntando a `gitops/policies` en `main`. El directorio contiene `disallow-latest.yaml`. Se utilizó `ServerSideApply=true`.

```bash
kubectl apply -f gitops/application.yaml
kubectl get applications -n argocd
```

**Experimento 1 — adopción de un recurso existente.** La política `disallow-latest` ya estaba instalada con `kubectl`. Argo CD mostró inicialmente `OutOfSync / Healthy`. En el DIFF se observó la anotación de seguimiento `argocd.argoproj.io/tracking-id` que Argo CD esperaba añadir. Tras sincronizar manualmente, la aplicación quedó `Synced / Healthy`. No fue necesario recrear la política.

**Experimento 2 — drift y self-healing.** Se modificó directamente en Kubernetes el `message` de la validación mediante `kubectl edit validatingpolicy disallow-latest`. Argo CD detectó `OutOfSync` y, mientras la sincronización era manual, conservó el cambio. Después se habilitó:

```yaml
syncPolicy:
  automated:
    selfHeal: true
    prune: false
  syncOptions:
    - ServerSideApply=true
```

Tras aplicar el cambio a la `Application`, Argo CD restauró el mensaje declarado en Git y volvió a `Synced`. `prune: false` evita la eliminación automática de recursos retirados del repositorio. La configuración actualizada se subió a GitHub.

### Application para workloads y mutación de admisión

Se restauró la `MutatingPolicy` `add-managed-label`, que actúa en operaciones `CREATE` de Pods dentro de namespaces `security-level=permissive` y añade `managed-by=kyverno`. La política quedó `READY=true`.

`gitops/workloads/nginx.yaml` declara un Pod `nginx-gitops` en `development`, imagen `nginx:1.27`, **sin** etiqueta `managed-by`. `gitops/workloads-application.yaml` crea la Application `kyverno-workloads` con `automated.selfHeal=true` y `ServerSideApply=true`.

```bash
kubectl apply -f add-managed-label.yaml
kubectl apply -f gitops/workloads-application.yaml
kubectl get pod nginx-gitops -n development --show-labels
kubectl get applications -n argocd
```

**Resultado observado:** el Pod estaba `Running`, tenía `managed-by=kyverno` y ambas aplicaciones (`kyverno-policies` y `kyverno-workloads`) aparecían `Synced / Healthy`.

**Conclusión acotada:** en esta configuración, la etiqueta adicional introducida por Kyverno durante la admisión **no provocó drift detectable ni un bucle de reconciliación** en Argo CD. Esto no garantiza el mismo resultado para otros campos, estrategias de mutación o configuraciones de comparación. La política probada solo intercepta `CREATE`; no demuestra el comportamiento de una competición continua entre controladores durante `UPDATE`.

### Verificaciones útiles

```bash
kubectl get applications -n argocd
kubectl get validatingpolicy disallow-latest
kubectl get mutatingpolicy add-managed-label
kubectl get pod nginx-gitops -n development --show-labels
kubectl get application kyverno-policies -n argocd -o yaml
kubectl get application kyverno-workloads -n argocd -o yaml
```

## 11. Limpieza (opcional)

> Ejecutar solo en un clúster de laboratorio: elimina los recursos creados durante los ejercicios.

```bash
kubectl delete validatingpolicy disallow-privileged disallow-latest allowed-registries --ignore-not-found
kubectl delete mutatingpolicy add-managed-label aaa-managed-label override-managed-label --ignore-not-found
kubectl delete application kyverno-workloads kyverno-policies -n argocd --ignore-not-found
# Atención: las Applications pueden tener finalizers que propaguen borrados.
kubectl delete namespace development production --ignore-not-found

# Si se quiere retirar Kyverno por completo:
# helm uninstall kyverno -n kyverno
```

## 12. Ideas para entrevistas

- **Validación:** `Deny` bloquea nuevas operaciones; `Audit` facilita una adopción progresiva.
- **Mutación:** útil para defaults, pero puede sobrescribir decisiones de los equipos y generar diferencias con GitOps.
- **Cobertura:** revisar contenedores normales, `initContainers`, `ephemeralContainers` y **subrecursos**.
- **Observabilidad:** `PolicyReports`, eventos y estado `READY` cuentan cosas distintas.
- **Operación:** validar en un clúster real; no confundir admisión con ejecución ni con reconciliación continua.
- **Entrega:** versionar políticas, probarlas antes de producción y documentar explícitamente los casos no cubiertos.
- **GitOps:** `OutOfSync` puede deberse a metadatos de seguimiento o a cambios funcionales; inspeccionar el DIFF antes de sincronizar.
- **Reconciliación:** `selfHeal` corrige drift del clúster respecto a Git, pero no es una barrera de admisión ni garantiza corrección instantánea.
- **Pruebas:** distinguir tests offline de CEL, integración real con admission webhooks y sincronización de GitOps.
