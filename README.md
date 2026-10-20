# Hands-on Kyverno

Este repositorio contiene ejemplos para practicar políticas de Kyverno sobre
Pods: mutar sus metadatos al crearlos y rechazar contenedores privilegiados.

## Instalar Kyverno

Añade el repositorio Helm y consulta las versiones disponibles:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm search repo kyverno/kyverno --versions | head -15
```

Instala la versión usada en este ejercicio:

```sh
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.9.1 \
  --wait \
  --timeout 5m
```

Comprueba que los componentes estén listos:

```sh
kubectl get pods -n kyverno
kubectl get deployments -n kyverno
```

Crear los namespaces

kubectl create namespace development
kubectl create namespace production

kubectl label namespace production \
  security-level=restricted

kubectl label namespace development \
  security-level=permissive

## Ejercicios

### Mutación de etiquetas

Los manifiestos `add-managed-label.yaml` y `add-managed-label-2.yaml`
contienen variantes de una `MutatingPolicy` llamada `add-managed-label`. La
política aplica a Pods nuevos en namespaces con la etiqueta
`security-level=permissive`:

- `add-managed-label-2.yaml` establece `managed-by: kyverno`.
- `add-managed-label.yaml` intenta conservar un valor `managed-by` existente y
  usar `kyverno` cuando no existe.

Los Pods `mutation-test.yaml` y `mutation-conflict.yaml` sirven para probar,
respectivamente, la asignación de la etiqueta y el caso en que ya existe el
valor `managed-by: developer`.

Antes de probar la mutación, crea el namespace de ejemplo y márcalo:

```sh
kubectl create namespace development
kubectl label namespace development security-level=permissive
```

Las dos variantes declaran el mismo nombre de política; aplica solo una a la
vez. Además, en `add-managed-label.yaml`, el bloque `mutations` aparece dentro
de `matchConstraints`; corrige su ubicación antes de aplicar ese manifiesto.

Con la variante `add-managed-label-2.yaml`, el flujo de prueba es:

```sh
kubectl apply -f add-managed-label-2.yaml
kubectl apply -f mutation-test.yaml
kubectl apply -f mutation-conflict.yaml
kubectl get pods -n development --show-labels
```

### Validación de contenedores privilegiados

`disallow-privileged.yaml` define una `ValidatingPolicy` que deniega la
creación o actualización de Pods si alguno de sus contenedores tiene
`securityContext.privileged: true`.

- `privileged-pod.yaml` es el caso que debe ser rechazado.
- `unprivileged-pod.yaml` usa `privileged: false` y debe ser aceptado.

Ambos manifiestos tienen el mismo nombre y namespace, así que prueba uno,
bórralo y luego prueba el otro:

```sh
kubectl apply -f disallow-privileged.yaml
kubectl apply -f unprivileged-pod.yaml
kubectl delete -f unprivileged-pod.yaml
kubectl apply -f privileged-pod.yaml
```

## Policy reports

Consulta los informes generados en todos los namespaces:

```sh
kubectl get policyreports -A
```
