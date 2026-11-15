# Firma de código

Guía para pasar de la `.ipa` sin firmar a una instalable, y de ahí a TestFlight.

## Qué necesitas

Una cuenta de Apple Developer. La gratuita sirve para instalar en tus propios
dispositivos con perfiles de 7 días; la de pago (99 USD/año) da perfiles de un año,
distribución ad-hoc y TestFlight.

Todo lo de abajo se hace **una vez** desde una Mac. Después, cada build sale del
runner de GitHub sin que toques nada.

## 1. Certificado (.p12)

En Xcode: **Settings → Accounts → tu Apple ID → Manage Certificates → +**.
Elige *Apple Development* para instalar en tus dispositivos, o *Apple Distribution*
para ad-hoc y App Store.

Luego, en **Acceso a Llaveros**: busca el certificado, despliégalo para ver la clave
privada, clic derecho → **Exportar 2 ítems** → formato `.p12`. Ponle una contraseña
y guárdala; es el secret `P12_PASSWORD`.

Conviértelo a base64:

```bash
base64 -i certificado.p12 | pbcopy
```

Eso es `BUILD_CERTIFICATE_BASE64`.

## 2. Provisioning profile

En [developer.apple.com](https://developer.apple.com/account/resources/profiles/list):

1. **Identifiers** → registra `com.aparataje.imgforge` y `com.aparataje.imgforge.share`.
   Son dos identificadores distintos: la extensión necesita el suyo.
2. **Devices** → añade el UDID de tu iPhone si vas por *development* o *ad-hoc*.
3. **Profiles** → crea uno por cada identificador, del tipo que corresponda.

Descarga el `.mobileprovision` de la app y conviértelo:

```bash
base64 -i ImgForge.mobileprovision | pbcopy
```

Eso es `PROVISIONING_PROFILE_BASE64`.

> El workflow actual importa un solo perfil. Si la extensión da problemas de firma,
> el camino corto es quitarla temporalmente de `project.yml`; el largo es añadir un
> segundo secret y repetir el bloque de importación.

## 3. Team ID

Aparece arriba a la derecha en developer.apple.com, bajo tu nombre. Diez caracteres
alfanuméricos. Es `TEAM_ID`.

## 4. Cargar los secrets

Repo → **Settings** → **Secrets and variables** → **Actions** → *New repository secret*.

| Secret | Contenido |
|--------|-----------|
| `BUILD_CERTIFICATE_BASE64` | el `.p12` en base64 |
| `P12_PASSWORD` | la contraseña que pusiste al exportar |
| `PROVISIONING_PROFILE_BASE64` | el `.mobileprovision` en base64 |
| `TEAM_ID` | tu Team ID |

## 5. Correr el build

**Actions** → *Build signed IPA* → **Run workflow**. Elige el método:

- **development** — instala en los dispositivos registrados en el perfil.
- **ad-hoc** — lo mismo, pero distribuible por enlace o Diawi.
- **app-store** — para TestFlight y la App Store.

El workflow importa el certificado en un llavero efímero, firma, exporta, **verifica
la firma con `codesign --verify --deep --strict`** y borra el llavero al terminar,
pase lo que pase.

## 6. TestFlight (opcional)

Necesita tres secrets más, de una API key de App Store Connect
(**Users and Access → Integrations → App Store Connect API**):

| Secret | De dónde sale |
|--------|---------------|
| `ASC_KEY_ID` | el ID de la key |
| `ASC_ISSUER_ID` | el Issuer ID de la página |
| `ASC_PRIVATE_KEY_BASE64` | el `.p8` descargado, en base64 |

El `.p8` se descarga **una sola vez**. Guárdalo.

Con eso, marca *Subir a TestFlight* y elige método `app-store`.

## Seguridad

- Los secrets nunca aparecen en los logs: GitHub los enmascara.
- El llavero se crea con una contraseña aleatoria por job y se destruye en el paso
  final, que corre con `if: always()`.
- El `.p12` y el perfil se borran del disco del runner al terminar.
- Aun así, un certificado de distribución es una credencial real. Si se filtra,
  revócalo en developer.apple.com y genera uno nuevo.

## Sin cuenta de desarrollador

La `.ipa` sin firmar que produce *Build unsigned IPA* se instala igual pasándola por
**Sideloadly** o **AltStore**, que la refirman con tu Apple ID gratuito en el momento.
Dura 7 días y hay que renovarla. Ambas herramientas corren en Mac o Windows.
