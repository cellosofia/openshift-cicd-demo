#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PRJ_PREFIX = "demo"
$COMMAND = "help"

$dev_prj = "$PRJ_PREFIX-dev"
$stage_prj = "$PRJ_PREFIX-stage"
$cicd_prj = "$PRJ_PREFIX-cicd"

function Write-Info {
    param([string]$Message)
    Write-Host ""
    Write-Host "# INFO: $Message" -ForegroundColor Cyan
}

function Write-Err {
    param([string]$Message)
    Write-Host ""
    Write-Host "# ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Wait-Seconds {
    param([int]$Count = 5)
    for ($i = 1; $i -le $Count; $i++) {
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 1
    }
    Write-Host ""
}

function Test-ValidCommand {
    param([string]$CommandName)
    $functionName = "Command-$CommandName"
    return (Get-Command -Name $functionName -ErrorAction SilentlyContinue) -ne $null
}

function Command-Help {
    Write-Host @"

  Usage:
      .\demo.ps1 [command] [options]

  Example:
      .\demo.ps1 install -ProjectPrefix mydemo

  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -ProjectPrefix [string]        Prefix to be added to demo project names e.g. PREFIX-dev
"@
}

function Wait-ForOperator {
    param(
        [string]$SubscriptionName,
        [string]$Namespace = "openshift-operators",
        [int]$MaxWait = 600
    )
    
    Write-Info "Esperando a que el operador de la subscription $SubscriptionName esté completamente instalado..."
    
    $elapsed = 0
    
    while ($elapsed -lt $MaxWait) {
        try {
            $subOutput = oc get subscription $SubscriptionName -n $Namespace -o json 2>$null
            if ($subOutput) {
                $subscription = $subOutput | ConvertFrom-Json
                $csv = $subscription.status.installedCSV
                
                if ($csv -and $csv -ne "null" -and $csv -ne "") {
                    $csvOutput = oc get csv $csv -n $Namespace -o json 2>$null
                    if ($csvOutput) {
                        $csvObj = $csvOutput | ConvertFrom-Json
                        $phase = $csvObj.status.phase
                        
                        if ($phase -eq "Succeeded") {
                            Write-Info "Operador $SubscriptionName instalado correctamente (CSV: $csv)"
                            return
                        }
                        
                        if ($phase -and $phase -ne "Succeeded") {
                            Write-Host -NoNewline "[$phase]"
                        }
                    }
                } else {
                    $installPlan = $subscription.status.installPlanRef.name
                    if ($installPlan -and $installPlan -ne "null" -and $installPlan -ne "") {
                        Write-Host -NoNewline "[installing]"
                    }
                }
            }
        } catch {
            # Subscription aún no existe o no tiene status
        }
        
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    
    Write-Err "Timeout esperando a que el operador $SubscriptionName se instale (esperado: $MaxWait segundos)"
}

function Install-OpenShiftPipelines {
    $namespace = "openshift-operators"
    
    Write-Info "Instalando operador OpenShift Pipelines..."
    
    # Verificar si el namespace openshift-operators existe
    $nsExists = oc get ns $namespace 2>$null
    if (-not $nsExists) {
        Write-Info "Creando namespace $namespace"
        oc create namespace $namespace | Out-Null
    }
    
    # Verificar si ya existe una subscription
    $subExists = oc get subscription openshift-pipelines-operator-rh -n $namespace 2>$null
    if ($subExists) {
        Write-Info "El operador OpenShift Pipelines ya está suscrito"
    } else {
        # Crear OperatorGroup si no existe
        $ogExists = oc get operatorgroup -n $namespace 2>$null
        if (-not $ogExists) {
            $operatorGroup = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
"@
            $operatorGroup | oc apply -f - | Out-Null
        }
        
        # Crear Subscription para OpenShift Pipelines
        $subscription = @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: $namespace
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
"@
        $subscription | oc apply -f - | Out-Null
    }
    
    Wait-ForOperator -SubscriptionName "openshift-pipelines-operator-rh" -Namespace $namespace
}

function Install-OpenShiftGitOps {
    $namespace = "openshift-operators"
    
    Write-Info "Instalando operador OpenShift GitOps..."
    
    # Verificar si el namespace openshift-operators existe
    $nsExists = oc get ns $namespace 2>$null
    if (-not $nsExists) {
        Write-Info "Creando namespace $namespace"
        oc create namespace $namespace | Out-Null
    }
    
    # Verificar si ya existe una subscription
    $subExists = oc get subscription openshift-gitops-operator -n $namespace 2>$null
    if ($subExists) {
        Write-Info "El operador OpenShift GitOps ya está suscrito"
    } else {
        # Crear OperatorGroup si no existe
        $ogExists = oc get operatorgroup -n $namespace 2>$null
        if (-not $ogExists) {
            $operatorGroup = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
"@
            $operatorGroup | oc apply -f - | Out-Null
        }
        
        # Crear Subscription para OpenShift GitOps
        $subscription = @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: $namespace
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
"@
        $subscription | oc apply -f - | Out-Null
    }
    
    Wait-ForOperator -SubscriptionName "openshift-gitops-operator" -Namespace $namespace
}

function Configure-RouterCA {
    Write-Info "Configurando el CA del router en el proxy del cluster..."
    
    # Verificar si el configmap ya existe y el proxy está configurado
    $cmExists = oc get configmap custom-ca -n openshift-config 2>$null
    if ($cmExists) {
        Write-Info "El configmap custom-ca ya existe, verificando si el proxy está configurado..."
        try {
            $proxyConfig = oc get proxy/cluster -o json 2>$null | ConvertFrom-Json
            if ($proxyConfig.spec.trustedCA -and $proxyConfig.spec.trustedCA.name -eq "custom-ca") {
                Write-Info "El proxy ya está configurado con el CA del router"
                return
            }
        } catch {
            # Continuar con la configuración
        }
    }
    
    # Extraer el CA del secret router-ca
    Write-Info "Extrayendo el CA del secret router-ca..."
    $caBase64 = oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>$null
    if (-not $caBase64) {
        Write-Err "No se pudo obtener el secret router-ca del namespace openshift-ingress-operator"
    }
    
    # Decodificar el base64
    $caBytes = [System.Convert]::FromBase64String($caBase64)
    $caContent = [System.Text.Encoding]::UTF8.GetString($caBytes)
    
    # Crear archivo temporal
    $tmpCaFile = Join-Path $env:TEMP "ingress-ca.crt"
    Set-Content -Path $tmpCaFile -Value $caContent -NoNewline
    
    # Crear o actualizar el configmap
    Write-Info "Creando configmap custom-ca en openshift-config..."
    oc create configmap custom-ca --from-file ca-bundle.crt=$tmpCaFile -n openshift-config --dry-run=client -o yaml | oc apply -f - | Out-Null
    
    # Parchear el proxy/cluster
    Write-Info "Configurando el proxy/cluster para usar el CA..."
    $patchJson = '{"spec":{"trustedCA":{"name":"custom-ca"}}}'
    oc patch proxy/cluster --type=merge -p $patchJson | Out-Null
    
    # Limpiar archivo temporal
    Remove-Item -Path $tmpCaFile -ErrorAction SilentlyContinue
    
    # Esperar a que los pods de openshift-apiserver se reinicien
    Write-Info "Esperando a que los pods de openshift-apiserver se reinicien..."
    Wait-ForApiserverRestart
}

function Wait-ForApiserverRestart {
    param([int]$MaxWait = 600)
    
    $namespace = "openshift-apiserver"
    $elapsed = 0
    
    # Esperar un poco para que los pods comiencen a reiniciarse
    Write-Info "Esperando a que los pods de $namespace se reinicien después de la configuración del proxy..."
    Start-Sleep -Seconds 30
    
    while ($elapsed -lt $MaxWait) {
        try {
            $pods = oc get pods -n $namespace -o json 2>$null | ConvertFrom-Json
            
            if ($pods.items.Count -eq 0) {
                Write-Host -NoNewline "."
                Start-Sleep -Seconds 10
                $elapsed += 10
                continue
            }
            
            $allReady = $true
            $allRunning = $true
            
            foreach ($pod in $pods.items) {
                $podStatus = $pod.status.phase
                
                # Verificar que el pod esté en estado Running
                if ($podStatus -ne "Running") {
                    $allRunning = $false
                    $allReady = $false
                    continue
                }
                
                # Verificar que el pod esté Ready
                if ($pod.status.conditions) {
                    $readyCondition = $pod.status.conditions | Where-Object { $_.type -eq "Ready" }
                    if (-not $readyCondition -or $readyCondition.status -ne "True") {
                        $allReady = $false
                    }
                } else {
                    $allReady = $false
                }
            }
            
            # Si todos los pods están Running y Ready, el reinicio completó
            if ($allRunning -and $allReady) {
                Write-Info "Los pods de $namespace se han reiniciado correctamente y están listos"
                return
            }
        } catch {
            # Error al obtener pods, continuar esperando
        }
        
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    
    Write-Err "Timeout esperando a que los pods de $namespace se reinicien (esperado: $MaxWait segundos)"
}

function Wait-ForPipelinesAsCodeRoute {
    param(
        [string]$Namespace = "openshift-pipelines",
        [int]$MaxWait = 600
    )
    
    $routeName = "pipelines-as-code-controller"
    Write-Info "Esperando a que la ruta $routeName esté disponible en el namespace $Namespace..."
    
    $elapsed = 0
    
    while ($elapsed -lt $MaxWait) {
        try {
            # Intentar obtener la ruta primero en openshift-pipelines
            $routeOutput = oc get route $routeName -n $Namespace -o jsonpath='{.spec.host}' 2>$null
            if ($routeOutput -and $routeOutput -ne "null" -and $routeOutput -ne "") {
                Write-Info "Ruta $routeName disponible en $Namespace (host: $routeOutput)"
                return
            }
            
            # Si no está en openshift-pipelines, intentar en pipelines-as-code
            if ($Namespace -eq "openshift-pipelines") {
                $routeOutput = oc get route $routeName -n pipelines-as-code -o jsonpath='{.spec.host}' 2>$null
                if ($routeOutput -and $routeOutput -ne "null" -and $routeOutput -ne "") {
                    Write-Info "Ruta $routeName disponible en pipelines-as-code (host: $routeOutput)"
                    return
                }
            }
        } catch {
            # Ruta aún no existe
        }
        
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    
    Write-Err "Timeout esperando a que la ruta $routeName esté disponible (esperado: $MaxWait segundos)"
}

function Command-Install {
    $env:GIT_SSL_NO_VERIFY = "true"
    
    $ocVersion = oc version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "no oc binary found"
    }
    
    Write-Info "Configurando CA del router en el proxy del cluster..."
    Configure-RouterCA
    
    Write-Info "Instalando operadores requeridos..."
    Install-OpenShiftPipelines
    Install-OpenShiftGitOps
    
    Write-Info "Esperando a que la ruta pipelines-as-code-controller esté disponible..."
    Wait-ForPipelinesAsCodeRoute -Namespace "openshift-pipelines"
    
    Write-Info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
    
    $ns = oc get ns $cicd_prj 2>$null
    if (-not $ns) {
        oc new-project $cicd_prj | Out-Null
    }
    
    $ns = oc get ns $dev_prj 2>$null
    if (-not $ns) {
        oc new-project $dev_prj | Out-Null
    }
    
    $ns = oc get ns $stage_prj 2>$null
    if (-not $ns) {
        oc new-project $stage_prj | Out-Null
    }
    
    Write-Info "Configure service account permissions for pipeline"
    oc policy add-role-to-user edit "system:serviceaccount:$cicd_prj:pipeline" -n $dev_prj | Out-Null
    oc policy add-role-to-user edit "system:serviceaccount:$cicd_prj:pipeline" -n $stage_prj | Out-Null
    oc policy add-role-to-user system:image-puller "system:serviceaccount:$dev_prj:default" -n $cicd_prj | Out-Null
    oc policy add-role-to-user system:image-puller "system:serviceaccount:$stage_prj:default" -n $cicd_prj | Out-Null
    
    Write-Info "Deploying CI/CD infra to $cicd_prj namespace"
    oc apply -f infra -n $cicd_prj | Out-Null
    
    $giteaHostname = oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj
    
    Write-Info "Initiatlizing git repository in Gitea and configuring webhooks"
    $webhookUrl = oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}" --ignore-not-found 2>$null
    if (-not $webhookUrl) {
        $webhookUrl = oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}"
    }
    
    $giteaConfig = Get-Content "config/gitea-configmap.yaml" -Raw
    $giteaConfig = $giteaConfig -replace '@HOSTNAME', $giteaHostname
    $giteaConfig | oc create -f - -n $cicd_prj | Out-Null
    
    oc rollout status deployment/gitea -n $cicd_prj | Out-Null
    
    $taskrunConfig = Get-Content "config/gitea-init-taskrun.yaml" -Raw
    $taskrunConfig = $taskrunConfig -replace '@webhook-url@', "https://$webhookUrl"
    $taskrunConfig = $taskrunConfig -replace '@gitea-url@', "https://$giteaHostname"
    $taskrunConfig | oc create -f - -n $cicd_prj | Out-Null
    
    Wait-Seconds -Count 20
    
    $running = $true
    while ($running) {
        $taskruns = oc get taskrun -n $cicd_prj 2>$null
        if ($taskruns -match "Running") {
            Write-Host "waiting for Gitea init..."
            Wait-Seconds -Count 10
        } else {
            $running = $false
        }
    }
    
    Write-Host "Waiting for source code to be imported to Gitea..."
    $imported = $false
    while (-not $imported) {
        try {
            $response = Invoke-WebRequest -Uri "https://$giteaHostname/gitea/spring-petclinic" -Method Head -SkipCertificateCheck -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) {
                $imported = $true
            }
        } catch {
            # Continue waiting
        }
        if (-not $imported) {
            Wait-Seconds -Count 10
        }
    }
    
    Wait-Seconds -Count 10
    Start-Sleep -Seconds 10
    
    Write-Info "Updating pipelinerun values for the demo environment"
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }
    Push-Location $tmpDir
    
    git clone "https://$giteaHostname/gitea/spring-petclinic"
    Set-Location spring-petclinic
    git config user.email "openshift-pipelines@redhat.com"
    git config user.name "openshift-pipelines"
    
    $buildYaml = Get-Content ".tekton/build.yaml" -Raw
    $buildYaml = $buildYaml -replace 'https://github.com/siamaksade/spring-petclinic-config', "https://$giteaHostname/gitea/spring-petclinic-config"
    Set-Content -Path ".tekton/build.yaml" -Value $buildYaml
    
    git add .tekton/build.yaml
    git commit -m "Updated manifests git url"
    git remote add auth-origin "https://gitea:openshift@$giteaHostname/gitea/spring-petclinic"
    git push auth-origin cicd-demo
    
    Pop-Location
    
    Write-Info "Configuring pipelines-as-code"
    $taskrunName = oc get taskrun -n $cicd_prj -o jsonpath="{.items[0].metadata.name}"
    $taskrunLogs = oc logs "$taskrunName-pod" -n $cicd_prj
    $giteaToken = ""
    $tokenLine = $taskrunLogs | Select-String -Pattern "Token" | Select-Object -First 1
    if ($tokenLine -match '## Token: (.*) ##') {
        $giteaToken = $matches[1].Trim()
    }
    
    $pacRepository = @"
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: spring-petclinic
  namespace: "$cicd_prj"
spec:
  url: https://$giteaHostname/gitea/spring-petclinic
  git_provider:
    user: git
    url: https://$giteaHostname
    secret:
      name: "gitea"
      key: token
    webhook_secret:
      name: "gitea"
      key: "webhook"
---
apiVersion: v1
kind: Secret
metadata:
  name: gitea
  namespace: $cicd_prj
type: Opaque
stringData:
  token: $giteaToken
  webhook: ""
"@
    
    $tmpPacFile = Join-Path $env:TEMP "tmp-pac-repository.yaml"
    Set-Content -Path $tmpPacFile -Value $pacRepository
    oc apply -f $tmpPacFile -n $cicd_prj | Out-Null
    
    Wait-Seconds -Count 10
    
    Write-Info "Configure Argo CD"
    
    $argocdAppPatch = @"
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: "$dev_prj"
  source:
    repoURL: https://$giteaHostname/gitea/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: "$stage_prj"
  source:
    repoURL: https://$giteaHostname/gitea/spring-petclinic-config
"@
    
    $tmpArgoFile = Join-Path $SCRIPT_DIR "argo/tmp-argocd-app-patch.yaml"
    Set-Content -Path $tmpArgoFile -Value $argocdAppPatch
    oc apply -k argo -n $cicd_prj | Out-Null
    
    Write-Info "Wait for Argo CD route..."
    
    $routeExists = $false
    while (-not $routeExists) {
        $route = oc get route argocd-server -n $cicd_prj 2>$null
        if ($route) {
            $routeExists = $true
        } else {
            Wait-Seconds -Count 10
        }
    }
    
    Write-Info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
    oc label ns $dev_prj "argocd.argoproj.io/managed-by=$cicd_prj" | Out-Null
    oc label ns $stage_prj "argocd.argoproj.io/managed-by=$cicd_prj" | Out-Null
    
    oc project $cicd_prj | Out-Null
    
    $sonarqubeHost = oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj
    $nexusHost = oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj
    $argocdHost = oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj
    
    Write-Host @"

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     https://$giteaHostname/gitea/spring-petclinic.git

  2) Log into Gitea with username/password: gitea/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    `$ opc pac logs -n $cicd_prj


  You can find further details at:

  Gitea Git Server: https://$giteaHostname/explore/repos
  SonarQube: https://$sonarqubeHost
  Sonatype Nexus: https://$nexusHost
  Argo CD:  http://$argocdHost  [login with OpenShift credentials]

############################################################################
############################################################################
"@
}

function Command-Start {
    $giteaHostname = oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj
    Write-Info "Pushing a change to https://$giteaHostname/gitea/spring-petclinic-config"
    
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }
    Push-Location $tmpDir
    
    git clone "https://$giteaHostname/gitea/spring-petclinic"
    Set-Location spring-petclinic
    git config user.email "openshift-pipelines@redhat.com"
    git config user.name "openshift-pipelines"
    
    Add-Content -Path "readme.md" -Value "   "
    git add readme.md
    git commit -m "Updated readme.md"
    git remote add auth-origin "https://gitea:openshift@$giteaHostname/gitea/spring-petclinic"
    git push auth-origin cicd-demo
    
    Pop-Location
}

function Command-Uninstall {
    oc delete project $dev_prj $stage_prj $cicd_prj
}

# Parse arguments
$argsList = $args
$i = 0
while ($i -lt $argsList.Length) {
    $arg = $argsList[$i]
    switch -Wildcard ($arg) {
        { $_ -in "install", "uninstall", "start", "help" } {
            $COMMAND = $_
            $i++
        }
        { $_ -in "-p", "--project-prefix", "-ProjectPrefix", "--ProjectPrefix" } {
            if ($i + 1 -lt $argsList.Length) {
                $PRJ_PREFIX = $argsList[$i + 1]
                $dev_prj = "$PRJ_PREFIX-dev"
                $stage_prj = "$PRJ_PREFIX-stage"
                $cicd_prj = "$PRJ_PREFIX-cicd"
                $i += 2
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        "--" {
            $i++
            break
        }
        "-*" {
            Write-Err "Error: Unsupported flag $arg"
        }
        default {
            $i++
        }
    }
}

# Main execution
Set-Location $SCRIPT_DIR

if ($COMMAND -eq "help") {
    Command-Help
    exit 0
}

$functionName = "Command-$COMMAND"
if (-not (Test-ValidCommand -CommandName $COMMAND)) {
    Write-Err "invalid command '$COMMAND'"
}

& $functionName

