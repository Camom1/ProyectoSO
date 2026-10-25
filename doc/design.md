# Diseño del Sistema Evaluador de Exámenes Médicos

**ST0257 — Sistemas Operativos**  
**Universidad EAFIT · 2026-2**  
**Autor:** Camilo Moreno  
**Fecha:** Octubre 2026  
**Plataforma:** Linux (WSL)  
**Lenguaje:** C  

---

## 1. Visión general del sistema

El sistema simula un analizador médico paralelo. Está compuesto por cinco componentes que se comunican a través de memoria compartida y semáforos POSIX:

```
[reg] → [cola de entrada] → [evaluador] → [cola de salida] → [rep]
                                 ↑
                             [robot reactivos]
```

- **reg**: registra muestras en las colas de entrada
- **evaluador**: proceso central con hilos que toman muestras, las procesan y las ponen en la salida
- **rep**: lee los resultados de la cola de salida
- **ctrl**: inspecciona y modifica el estado del sistema
- **robot**: único recurso que recarga reactivos (exclusión mutua)

Todo el estado compartido vive en **un único segmento de memoria compartida** llamado `evaluator` (por defecto).

---

## 2. Programas del sistema

El único ejecutable que ve el usuario es `evaluator`. Internamente lanza y coordina el proceso evaluador.

### 2.1 `evaluator init`

Crea e inicializa el segmento de memoria compartida. Lanza el proceso evaluador y se queda corriendo en la consola.

```
evaluator init [-i <int>] [-ie <int>] [-oe <int>] [-n <string>]
               [-b <int>] [-d <int>] [-s <int>] [-q <int>]
```

| Parámetro | Descripción | Default |
|-----------|-------------|---------|
| `-i`  | Número de colas de entrada | 5 |
| `-ie` | Posiciones por cola de entrada | 6 |
| `-oe` | Posiciones en la cola de salida | 10 |
| `-n`  | Nombre del segmento de memoria compartida | `evaluator` |
| `-b`  | Nivel inicial de reactivo Blood | 100 |
| `-d`  | Nivel inicial de reactivo Detritus | 100 |
| `-s`  | Nivel inicial de reactivo Skin | 100 |
| `-q`  | Tamaño de las colas internas del evaluador | 6 |

**Variables de ambiente:** ninguna requerida.

### 2.2 `evaluator reg`

Registra muestras en el sistema. Puede correr varias instancias al mismo tiempo.

```
evaluator reg [-n <string>] { <filename> ... | - }
```

- `-n`: nombre del segmento de memoria compartida (default: `evaluator`)
- `<filename>`: archivo con muestras. Si no existe, se ignora sin error.
- `-`: lee de la entrada estándar (modo interactivo)

**Formato de cada muestra:**
```
<bandeja> {B|D|S} <cantidad>
```
- `bandeja`: número de 0 a i−1
- `B|D|S`: tipo de muestra (Blood, Detritus, Skin)
- `cantidad`: entero de 1 a 5

**Salida:** un identificador único por muestra. Si viene de archivo, genera un archivo `.spl` con los mismos identificadores.

### 2.3 `evaluator ctrl`

Modo interactivo para inspeccionar y modificar el sistema.

```
evaluator ctrl [-s <string>]
```

Acepta los subcomandos `list` y `update` hasta encontrar EOF.

**`list [processing | waiting | reported | reactive | all]`**

| Subcomando | Formato de salida |
|------------|-------------------|
| `processing` | `[id i k q p]` — id, cola, tipo, cantidad, tiempo de procesamiento (seg) |
| `waiting`    | `[id i k q]` — id, cola, tipo, cantidad |
| `reported`   | `[id i k r]` — id, cola, tipo, resultado (negative/positive/-) |
| `reactive`   | nivel actual de B, D y S |
| `all`        | todo lo anterior |

**`update {B|D|S} <cantidad>`**  
Suma `cantidad` al nivel de reactivo del tipo indicado.

### 2.4 `evaluator rep`

Obtiene los reportes listos y los libera de la cola de salida.

```
evaluator rep [-s <string>] { -i <int> | -m <int> }
```

- `-i <seg>`: modo interactivo, espera ese tiempo entre reportes
- `-m <n>`: obtiene hasta n exámenes; si no hay suficientes, espera

**Formato de salida:**
```
[id i k r]
```
Donde `r` es: `N` (negativo), `P` (positivo), `?` (no concluyente).

---

## 3. Estructura de la memoria compartida

Todo lo compartido entre procesos vive en un único segmento POSIX creado con `shm_open` y mapeado con `mmap`.

### 3.1 Layout general

```c
typedef struct {
    /* Metadatos del sistema */
    int num_entradas;        /* número de colas de entrada (i) */
    int tam_entrada;         /* posiciones por cola (ie) */
    int tam_salida;          /* posiciones en cola de salida (oe) */
    int tam_cola_interna;    /* tamaño colas internas (q) */

    /* Niveles de reactivo */
    int reactivo_B;
    int reactivo_D;
    int reactivo_S;

    /* Semáforos de las colas de entrada (uno por cola × 3) */
    sem_t mutex_entrada[MAX_ENTRADAS];
    sem_t llenos_entrada[MAX_ENTRADAS];
    sem_t vacios_entrada[MAX_ENTRADAS];

    /* Cola de entrada: arreglo bidimensional de muestras */
    Muestra colas_entrada[MAX_ENTRADAS][MAX_IE];
    int cabeza_entrada[MAX_ENTRADAS];
    int cola_entrada_idx[MAX_ENTRADAS];
    int count_entrada[MAX_ENTRADAS];

    /* Semáforos de la cola de salida */
    sem_t mutex_salida;
    sem_t llenos_salida;
    sem_t vacios_salida;

    /* Cola de salida */
    Resultado cola_salida[MAX_OE];
    int cabeza_salida;
    int cola_salida_idx;
    int count_salida;

    /* Semáforo del robot (exclusión mutua) */
    sem_t mutex_robot;

    /* Contador global de IDs */
    sem_t mutex_id;
    int   ultimo_id;

} MemoriaCompartida;
```

### 3.2 Estructura de una muestra

```c
typedef struct {
    int  id;         /* identificador único */
    int  bandeja;    /* cola de entrada (0 a i-1) */
    char tipo;       /* 'B', 'D' o 'S' */
    int  cantidad;   /* 1 a 5 */
} Muestra;
```

### 3.3 Estructura de un resultado

```c
typedef struct {
    int  id;
    int  bandeja;
    char tipo;
    char resultado;  /* 'P', 'N' o '?' */
} Resultado;
```

---

## 4. Modelo de concurrencia

### 4.1 Productor-consumidor en las colas de entrada

Cada cola de entrada es un buffer circular compartido entre los procesos `reg` (productores) y los hilos de entrada del evaluador (consumidores).

Cada cola tiene **3 semáforos**:

| Semáforo | Valor inicial | Para qué sirve |
|----------|--------------|----------------|
| `mutex_entrada[i]` | 1 | Garantiza que solo un proceso accede a la cola a la vez (exclusión mutua) |
| `vacios_entrada[i]` | `ie` (6) | Cuenta las posiciones libres. El productor espera aquí si la cola está llena |
| `llenos_entrada[i]` | 0 | Cuenta las posiciones ocupadas. El consumidor espera aquí si la cola está vacía |

**Productor (reg) para agregar una muestra:**
```c
sem_wait(&mem->vacios_entrada[i]);   // espera si está llena
sem_wait(&mem->mutex_entrada[i]);    // entra a la sección crítica
  // pone la muestra en la cola
sem_post(&mem->mutex_entrada[i]);    // sale de la sección crítica
sem_post(&mem->llenos_entrada[i]);   // avisa que hay una muestra nueva
```

**Consumidor (hilo de entrada del evaluador) para tomar una muestra:**
```c
sem_wait(&mem->llenos_entrada[i]);   // espera si está vacía
sem_wait(&mem->mutex_entrada[i]);    // entra a la sección crítica
  // toma la muestra
sem_post(&mem->mutex_entrada[i]);    // sale de la sección crítica
sem_post(&mem->vacios_entrada[i]);   // avisa que liberó un espacio
```

### 4.2 Productor-consumidor en la cola de salida

Misma estructura, pero con una sola cola compartida entre todos los hilos de procesamiento (productores) y los procesos `rep` (consumidores).

| Semáforo | Valor inicial | Para qué sirve |
|----------|--------------|----------------|
| `mutex_salida` | 1 | Exclusión mutua sobre la cola de salida |
| `vacios_salida` | `oe` (10) | Posiciones libres; el evaluador espera si la cola de salida está llena |
| `llenos_salida` | 0 | Resultados listos; `rep` espera si no hay nada |

### 4.3 Robot de reactivos (exclusión mutua)

El robot es el único recurso que puede recargar reactivos. Solo puede atender un analizador a la vez. Se modela con un único semáforo binario (mutex):

| Semáforo | Valor inicial | Para qué sirve |
|----------|--------------|----------------|
| `mutex_robot` | 1 | Garantiza que solo un hilo usa el robot a la vez |

**Uso:**
```c
sem_wait(&mem->mutex_robot);   // toma el robot
  // recarga el reactivo del analizador
sem_post(&mem->mutex_robot);   // libera el robot
```

### 4.4 Generación de IDs únicos

Cada muestra registrada recibe un ID único y creciente. Como pueden existir varias instancias de `reg` al mismo tiempo, el contador se protege con un semáforo:

| Semáforo | Valor inicial | Para qué sirve |
|----------|--------------|----------------|
| `mutex_id` | 1 | Garantiza que dos `reg` no asignen el mismo ID |

---

## 5. Proceso evaluador e hilos internos

El evaluador es un proceso lanzado por `init`. Crea dos grupos de hilos:

### 5.1 Hilos de entrada (uno por cola)

- Hay `i` hilos de este tipo (5 por defecto)
- Cada hilo lee su cola de entrada continuamente
- Cuando toma una muestra, la coloca en la **cola interna** del tipo correspondiente (B, D o S)
- Las colas internas son arreglos en memoria del proceso — no están en la memoria compartida

### 5.2 Hilos de procesamiento de muestra (uno por tipo: B, D, S)

- Hay 3 hilos de este tipo
- Cada hilo toma muestras de su cola interna y las procesa
- El tiempo de procesamiento es aleatorio según el tipo:
  - B: entre 1 y 7 segundos
  - D: entre 5 y 20 segundos
  - S: entre 8 y 25 segundos
- Antes de procesar verifica si hay reactivo suficiente; si no, llama al robot
- El resultado se genera aleatoriamente: P (50%), N (35%), ? (15%)
- Al terminar, pone el resultado en la cola de salida compartida

### 5.3 Diagrama de hilos

```
evaluador (proceso)
├── hilo_entrada[0]  → cola_interna_B / cola_interna_D / cola_interna_S
├── hilo_entrada[1]  → cola_interna_B / cola_interna_D / cola_interna_S
├── hilo_entrada[2]  → cola_interna_B / cola_interna_D / cola_interna_S
├── hilo_entrada[3]  → cola_interna_B / cola_interna_D / cola_interna_S
├── hilo_entrada[4]  → cola_interna_B / cola_interna_D / cola_interna_S
├── hilo_proceso_B   → cola_salida (memoria compartida)
├── hilo_proceso_D   → cola_salida (memoria compartida)
└── hilo_proceso_S   → cola_salida (memoria compartida)
```

---

## 6. Resumen de semáforos

| Semáforo | Cantidad | Valor inicial | Propósito |
|----------|----------|---------------|-----------|
| `mutex_entrada[i]` | 5 (uno por cola) | 1 | Exclusión mutua en cada cola de entrada |
| `vacios_entrada[i]` | 5 | 6 | Espacios libres por cola de entrada |
| `llenos_entrada[i]` | 5 | 0 | Muestras pendientes por cola |
| `mutex_salida` | 1 | 1 | Exclusión mutua en la cola de salida |
| `vacios_salida` | 1 | 10 | Espacios libres en la cola de salida |
| `llenos_salida` | 1 | 0 | Resultados listos para leer |
| `mutex_robot` | 1 | 1 | Exclusión mutua sobre el robot |
| `mutex_id` | 1 | 1 | Exclusión mutua para generar IDs únicos |
| **Total** | **19** | | |

---

## 7. Jerarquía de directorios

```
evaluador/
├── Makefile
├── Readme.md
├── Install.md
├── src/          ← código fuente (.c y .h)
├── bin/          ← ejecutables compilados (no se sube al repo)
├── doc/
│   └── design.md ← este documento
└── examples/     ← archivos de muestra para reg
```

---

## 8. Ejemplo de uso

```bash
# 1. Iniciar el sistema
evaluator init -i 3 -ie 6 -oe 10

# 2. Registrar muestras desde archivo (en otra terminal)
evaluator reg muestras.txt

# Formato de muestras.txt:
# 0 B 2
# 1 D 4
# 2 S 1

# 3. Ver estado del sistema
evaluator ctrl
> list all

# 4. Obtener reportes
evaluator rep -m 5
```
