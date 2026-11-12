// instrumentation.js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');

const sdk = new NodeSDK({
  // The exporter will automatically look for the OTEL_EXPORTER_OTLP_TRACES_ENDPOINT env var
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT || 'http://tempo-cluster-ops.observability.svc.cluster.local:4318/v1/traces',
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Configure built-in HTTP instrumentation to ignore noisy poll endpoints
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req) => {
          const url = req.url || '';
          return url.includes('/metrics') || url.includes('/health');
        },
      },
      // Disable fs instrumentation to keep traces clean from disk reads
      '@opentelemetry/instrumentation-fs': {
        enabled: false,
      }
    }),
  ],
});

sdk.start();

// Ensure traces are flushed when the pod terminates
process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('Tracing terminated'))
    .catch((error) => console.log('Error terminating tracing', error))
    .finally(() => process.exit(0));
});