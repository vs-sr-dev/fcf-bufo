# Fairchild Channel F — architettura e toolchain

> Note prese sul campo per il porting di *BUFO*. Ogni numero qui dentro è
> stato verificato su una fonte primaria: il driver MAME `fairchild/channelf.cpp`
> + `channelf_v.cpp`, il backend F8 di `dasm` (`src/mnef8.c`), e le pagine
> tecniche di [veswiki](https://channelf.se/veswiki/).

---

## 1. Perché questa macchina è strana

Il Channel F (1976) è la **prima console a cartucce con una CPU vera**. È di un
anno *prima* dell'Atari 2600, e questo si vede in un modo controintuitivo:

- L'Atari 2600 ha una CPU normale (6502) e un video chip infernale (TIA) che ti
  obbliga a inseguire il pennello elettronico riga per riga (*racing the beam*).
- Il Channel F fa **l'opposto**: ha un video *facile* (framebuffer vero, che
  l'hardware rinfresca da solo: nessun timing da rispettare, nessun vblank da
  inseguire) ma una CPU **aliena** e una quantità di RAM che è una barzelletta.

Il risultato è che sul Channel F la difficoltà non è il video: è **far stare il
gioco in 64 byte di RAM**.

---

## 2. Il chipset F8

Il "F8" non è un chip, è una **famiglia di chip che si dividono il lavoro** —
un'architettura multi-chip, tipica del 1975:

| Chip | Ruolo |
|---|---|
| **3850 CPU** | ALU 8 bit, **64 byte di RAM interna** (scratchpad), 2 porte di I/O |
| **3851 PSU** | *Program Storage Unit*: 1 KiB di ROM + timer programmabile + logica interrupt + 2 porte I/O |
| 3852 / 3853 | interfacce memoria (DRAM / SRAM) — usate solo da alcune cartucce |

Nella console ci sono **due 3851**, che formano la BIOS da 2 KiB:

| Range | Contenuto | File ROM |
|---|---|---|
| `$0000-$03FF` | BIOS parte 1 | `sl31253.rom` |
| `$0400-$07FF` | BIOS parte 2 | `sl31254.rom` |
| `$0800-...`   | **cartuccia** | il nostro `.bin` |

Il terzo file, `sl90025.rom`, è la revisione usata dai modelli successivi
(System II): MAME lo richiede comunque nel romset.

Fatto cruciale: **non esiste RAM di sistema**. I 64 byte dentro la 3850 sono
tutta la memoria scrivibile che hai. Non c'è uno stack in RAM, non c'è un heap,
non c'è un'area variabili. Ci sono 64 registri e basta.

### 2.1 Modello di programmazione della 3850

```
A                 accumulatore, 8 bit
W                 status/flag: sign, carry, zero, overflow, interrupt-enable
ISAR              puntatore a 6 bit dentro lo scratchpad (vedi sotto)
r0 .. r63         scratchpad: 64 byte. QUESTA È LA RAM.
PC0               program counter
PC1               *un solo* livello di indirizzo di ritorno
DC0, DC1          data counter: i "puntatori" per leggere/scrivere memoria
```

Alcuni registri dello scratchpad hanno un doppio nome perché la CPU li usa come
coppie a 16 bit:

| Registri | Nome coppia | Uso |
|---|---|---|
| r9 | `J` | temporaneo per salvare `W` |
| r10:r11 | `H` (`HU`:`HL`) | salvataggio di `DC0` |
| r12:r13 | `K` (`KU`:`KL`) | salvataggio di `PC1` → **subroutine annidate** |
| r14:r15 | `Q` (`QU`:`QL`) | altro salvataggio 16 bit |

⚠️ Nel campo registro delle istruzioni ci sono solo 4 bit, e i valori 12/13/14
sono riservati alle modalità ISAR. Quindi **r12–r15 non sono indirizzabili
direttamente**: ci si arriva solo con i nomi `K`/`Q` o via ISAR.

### 2.2 ISAR: l'indirizzamento indiretto (e la sua trappola)

`ISAR` è un puntatore a 6 bit dentro lo scratchpad, ma è **spezzato in due
metà da 3 bit**:

```
ISAR = [ ISARU (3 bit) | ISARL (3 bit) ]
         banco 0..7      indice 0..7
```

- `lisu n` scrive i 3 bit alti (il banco), `lisl n` i 3 bit bassi.
- Nelle istruzioni, il registro `(IS)` legge/scrive dove punta ISAR;
  `(IS)+` e `(IS)-` post-incrementano/decrementano.

**La trappola**: `(IS)+` incrementa **solo i 3 bit bassi**, che *wrappano*
dentro il banco da 8. Passando da r23 non arrivi a r24: torni a r16.

Quindi lo scratchpad va pensato come **8 banchi da 8 byte**, e ogni array del
gioco va allineato a un banco. Non è un dettaglio: è il vincolo che detta
l'intero layout della memoria di *BUFO*.

### 2.3 Le istruzioni che contano

| Istruzione | Significato |
|---|---|
| `lr d,s` | move fra registri (`lr a,3`, `lr 3,a`, `lr a,(is)+`, `lr k,p`, …) |
| `li n` / `lis n` | carica immediato (`lis` = 1 byte, solo 0–15) |
| `clr` / `com` / `inc` | A=0 / A=~A / A=A+1 |
| `as r` / `ns r` / `xs r` | A += r / A &= r / A ^= r |
| `ai n` / `ni` / `oi` / `xi` / `ci` | aritmetica/logica immediata (`ci` = confronta) |
| `ds r` | **decrementa un registro** dello scratchpad e setta i flag → contatori di loop |
| `sl 1` `sl 4` `sr 1` `sr 4` | shift, solo di 1 o 4 posizioni |
| `dci addr` | DC0 = addr |
| `lm` / `st` | A = M(DC0), DC0++ / M(DC0) = A, DC0++ |
| `adc` | **DC0 += A** (con segno) → indicizzazione di tabelle |
| `xdc` | scambia DC0 e DC1 |
| `pi addr` | call: PC1 = ritorno, PC0 = addr |
| `pop` | return: PC0 = PC1 |
| `jmp addr` | salto assoluto — ⚠️ **distrugge A** |
| `br addr` | salto relativo (−128…+127), non tocca A |
| `bt m,a` / `bf m,a` | branch su maschera di flag; alias: `bp bc bz bnz bnc bm bno` |
| `ins n` / `outs n` | A = porta n / porta n = A |

Due cose da memorizzare subito:

1. **`jmp` distrugge l'accumulatore.** Usa `br` dove puoi.
2. **C'è un solo livello di return** (`PC1`). Per annidare le chiamate devi
   salvare a mano l'indirizzo di ritorno:

```asm
    ; siamo dentro una subroutine e vogliamo chiamarne un'altra
    lr   k,p        ; K (r12:r13) = PC1, cioè il nostro indirizzo di ritorno
    pi   altra_sub
    lr   p,k        ; ripristina PC1
    pop             ; return
```

Con `K` arrivi a profondità 2, con `Q` a 3. Oltre, ti serve uno stack software.

---

## 3. Video: 128×64, 2 bit per pixel, **write-only**

La VRAM è **2 KiB di DRAM separata**, che l'hardware video scandisce da solo.
Conseguenze:

- ✅ **Non serve sincronizzarsi col raster.** Scrivi quando vuoi, resta a schermo.
- ❌ La CPU **non può rileggere la VRAM**. È solo scrittura. Se ti serve sapere
  cosa c'è a schermo, devi tenerne traccia… nei tuoi 64 byte.

Layout: 128 colonne × 64 righe, **2 bit per pixel**.

### 3.1 Area visibile

| | |
|---|---|
| Buffer | 128 × 64 |
| Visibile | ~102 × 58, a partire da colonna 4, riga 4 |
| *Safe area* | ~95 × 58 |

Le colonne 125 e 126 **non sono grafica**: sono i bit di palette della riga.

### 3.2 Le quattro porte

| Porta | Scrittura | Lettura |
|---|---|---|
| **0** | bit 5 = **impulso di scrittura VRAM**; bit 6 = 1 disabilita i controller | pulsanti frontali (bit 0–3: TIME, HOLD, MODE, START) |
| **1** | bit 7–6 = **valore del pixel, complementato** | controller **destro** |
| **4** | **colonna** (7 bit), complementata | controller **sinistro** |
| **5** | **riga** (6 bit), complementata; bit 7–6 = **suono** | — |

Tutti gli ingressi e gli indirizzi sono **attivi bassi**: da qui il `com` che
troverai sparso in tutto il codice. La logica esatta nel driver MAME è:

```cpp
// port 4 write
m_col_reg = (data | 0x80) ^ 0xff;      // colonna = complemento dei bit 0-6
// port 5 write
m_row_reg = (data | 0xc0) ^ 0xff;      // riga    = complemento dei bit 0-5
m_custom->sound_w((data >> 6) & 3);    // e i bit alti sono il suono
// port 1 write
m_val_reg = ((data ^ 0xff) >> 6) & 0x03;   // pixel  = complemento dei bit 7-6
// port 0 write
if (data & 0x20) m_p_videoram[m_row_reg*128 + m_col_reg] = m_val_reg;
```

Quindi **plottare un pixel = quattro OUT**: colore su porta 1, X su porta 4,
Y su porta 5, e infine l'impulso su porta 0.

Byte da scrivere su porta 1 → valore del pixel:

| Porta 1 | Valore pixel |
|---|---|
| `$C0` | 0 (sfondo) |
| `$80` | 1 |
| `$40` | 2 |
| `$00` | 3 |

### 3.3 Colore: 4 palette, **una per riga**

Il colore finale è `colormap[palette_della_riga * 4 + valore_del_pixel]`, dove la
tabella (da `channelf_v.cpp`) è:

```c
static const uint16_t colormap[] = {
    BLACK,   WHITE, WHITE, WHITE,     // palette 0
    LTBLUE,  BLUE,  RED,   GREEN,     // palette 1
    LTGRAY,  BLUE,  RED,   GREEN,     // palette 2
    LTGREEN, BLUE,  RED,   GREEN,     // palette 3
};
```

Gli 8 colori fisici:

| Nome | RGB |
|---|---|
| BLACK | `#101010` |
| WHITE | `#FDFDFD` |
| RED | `#FF3153` |
| GREEN | `#02CC5D` |
| BLUE | `#4B3FF3` |
| LTGRAY | `#E0E0E0` |
| LTGREEN | `#91FFA6` |
| LTBLUE | `#CED0FF` |

Leggilo così: **il valore 0 è "lo sfondo" e cambia con la palette; i valori
1/2/3 sono sempre blu/rosso/verde** (tranne nella palette 0, che è
bianco su nero).

Cioè: hai **un solo piano grafico a 3 colori più uno sfondo, e lo sfondo lo
scegli riga per riga**. Nient'altro. Nessuno sprite, nessun hardware di
collisione, nessuno scrolling.

### 3.4 Come si seleziona la palette di una riga

MAME:

```cpp
palette_offset = ((reg2 & 0x2) | (reg1 >> 1)) << 2;
// reg1 = videoram[y*128 + 125], reg2 = videoram[y*128 + 126]
```

Tradotto: la palette della riga `y` è formata dal **bit 1 del pixel in colonna
125** (bit basso) e dal **bit 1 del pixel in colonna 126** (bit alto).

Il bit 1 è alto nei valori 2 e 3. Quindi:

| Vuoi il bit… | Scrivi in col. 125/126 |
|---|---|
| 1 (set) | valore 2 o 3 → porta 1 = `$40` o `$00` |
| 0 (clear) | valore 0 o 1 → porta 1 = `$C0` o `$80` |

Essendo fuori dall'area visibile, il colore che ci finisce è irrilevante: contano
solo i bit.

---

## 4. Suono

Tre toni fissi, sui bit 7–6 della porta 5: `00` = silenzio, `01`/`10`/`11` = tre
frequenze. Il tono **decade da solo** (è un RC), quindi va ri-innescato. È tutto.
Non c'è un canale, non c'è un volume, non c'è un inviluppo.

Nota pratica: la porta 5 porta *anche* la riga della VRAM. Ogni volta che
plotti un pixel scrivi sulla porta 5, e quindi **toccheresti il suono**. I bit
di suono vanno quindi mantenuti nel byte della riga a ogni scrittura.

---

## 5. Controller

Il "grip stick" del Channel F è un plettro che fa 8 cose: 4 direzioni, torsione
in due sensi, e tira/spingi. Tutto **attivo basso** → si legge e si fa `com`.

| Bit | Funzione |
|---|---|
| 0 | destra |
| 1 | sinistra |
| 2 | indietro (giù) |
| 3 | avanti (su) |
| 4 | torsione antiorario |
| 5 | torsione orario |
| 6 | tira su |
| 7 | spingi giù |

Idioma di lettura (il `clr`+`outs` azzera il latch, altrimenti i bit restano
forzati a 1):

```asm
    clr
    outs 0          ; abilita i controller (bit 6 = 0) e azzera il latch
    outs 1
    ins  1          ; legge il controller destro
    com             ; ora 1 = premuto
```

I pulsanti frontali (TIME/HOLD/MODE/START) stanno sulla porta 0, bit 0–3,
anch'essi attivi bassi.

---

## 6. Formato cartuccia

La ROM parte a `$0800`. Il BIOS, al reset, **confronta il primo byte con `$55`**;
se non combacia lancia i giochi interni (Hockey/Tennis). Poi salta a `$0802`.

```asm
    org  $0800
    db   $55        ; "cartuccia valida"
    nop
    ; l'esecuzione comincia qui, a $0802
```

Le cartucce originali erano da 2 KiB (`$0800-$0FFF`) o 4 KiB.

Il BIOS resta mappato e **leggibile**: puoi usare le sue routine (`clrscrn` a
`$00D0`, `drawchar` a `$0679`, …) oppure ignorarle e leggerti solo i suoi dati,
per esempio il font 5×8 che sta intorno a `$0674`. Attenzione però: le routine
BIOS si riservano dei registri (`r59` come stack pointer, `r40-r58` come stack
per `K`), e quei byte sono preziosi.

---

## 7. Toolchain usata in questo progetto

| Pezzo | Scelta | Note |
|---|---|---|
| Assembler | **dasm** 2.20.16 | supporta l'F8 ufficialmente (`processor f8`); compilato da sorgente con MinGW64 |
| Emulatore | **MAME** 0.287, driver `channelf` | serve il romset BIOS (`sl31253/31254/90025.rom`) |
| Alternative | asmx, f8tool | Emma 02 come emulatore alternativo |

Particolarità del backend F8 di dasm:

- `DS` è un'istruzione F8, quindi la direttiva "define space" si chiama **`RES`**.
- Non ottimizza: `li 0` genera 2 byte, `lis 0` ne genera 1. Scegli tu.
- Registri: `0`–`11` diretti, `(is)`/`(is)+`/`(is)-` (o gli alias `s`/`i`/`d`),
  più i nomi speciali `a dc0 h is k ku kl pc0 pc1 q qu ql w` e `j hu hl`.
- Parentesi tonde e quadre sono equivalenti nelle espressioni.

---

## 8. Conseguenze di progetto per BUFO

Mettendo insieme i vincoli:

1. **64 byte di RAM** → niente lista di oggetti. Ogni corsia è *una variabile*:
   un offset di scorrimento. Le auto e i tronchi sono un **pattern periodico
   generato**, non entità. La collisione si calcola aritmeticamente
   dall'offset della corsia, non leggendo lo schermo (impossibile, la VRAM non
   si rilegge).
2. **VRAM write-only** → serve una regola di redraw disciplinata: cancello la
   riga precedente del rospo e la ridisegno; le corsie si ridisegnano per
   intero quando scorrono di 1 pixel.
3. **Palette per riga** → il layout verticale del gioco *è* la scelta dei colori:

| Fascia | Palette | Sfondo | Oggetti |
|---|---|---|---|
| punteggio | 0 | nero | testo bianco |
| tane (home) | 3 | verde chiaro | divisori blu |
| fiume | 1 | azzurro | tronchi/tartarughe **blu** |
| spartitraffico | 3 | verde chiaro | — |
| strada | 2 | grigio chiaro | auto **rosse**, strisce blu |
| partenza | 3 | verde chiaro | — |

   Il rospo è **verde** su tutte le fasce: verde scuro su verde chiaro, su
   grigio e su azzurro si legge sempre. È l'unico colore che funziona
   dappertutto, dato che nessuna fascia usa il verde come sfondo.
4. **Un solo livello di return** → gerarchia di chiamate piatta, con `K` usato
   esplicitamente dove serve profondità 2.
