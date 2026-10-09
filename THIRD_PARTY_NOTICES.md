# Third-party software and models

The library and server code are licensed under [MIT](LICENSE). Dependencies and model weights
retain their upstream licenses; the server's license does not relicense them.

## Direct dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/0.17.7): Apache-2.0.
  CoreML model loading and speech recognition, by Fluid Inference and contributors.
  Its bundled components have [additional notices](https://github.com/FluidInference/FluidAudio/tree/0.17.7/ThirdPartyLicenses).
- [Hummingbird](https://github.com/hummingbird-project/hummingbird/tree/2.27.0): Apache-2.0.
- [MultipartKit](https://github.com/vapor/multipart-kit/tree/4.7.1): MIT.
- [swift-log](https://github.com/apple/swift-log/tree/1.16.1): Apache-2.0.
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser/tree/1.8.2): Apache-2.0.

Swift Package Manager fetches these dependencies from their upstream repositories,
including their license files. Transitive dependencies retain their own licenses.
Binary redistributions must also preserve applicable upstream notices.

## Speech models

Model weights are downloaded separately by FluidAudio on first use and are not
included in this repository. NVIDIA created the Parakeet base models; Fluid Inference
provides the CoreML conversions and Swift integration. Moondream created the Ultra
post-training. This server uses the downloaded weights without modifying them.

| Option | CoreML model and license information | Original model |
|---|---|---|
| `unified` | [FluidInference/parakeet-unified-en-0.6b-coreml](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml) | [NVIDIA Parakeet Unified](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) |
| `ultra` | [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), based on NVIDIA Parakeet TDT v3 |
| `v2` | [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) | [NVIDIA Parakeet TDT v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) |
| `v3` | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | [NVIDIA Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) |

The default Unified model is released under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Refer to the linked model
repositories for each variant's current terms and attribution information.
