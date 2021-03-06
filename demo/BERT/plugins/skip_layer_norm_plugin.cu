/*
 * Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "NvInfer.h"
#include "logger.h"
#include "plugin_kernels.hpp"
#include "plugin_util.hpp"
#include "skip_layer_norm_plugin.hpp"

#include <cassert>
#include <cstring>
#include <vector>

template <typename T, unsigned TPB>
__global__ void skip_layer_norm_kernel_small(
    int ld, const T* input, const T* skip, const float* beta, const float* gamma, T* output)
{

    T rld = T(1) / T(ld);
    int offset = blockIdx.x * ld;

    cub::Sum pairSum;
    // reduce x and x^2
    kvp<T> thread_data(0, 0);
    int idx = offset + threadIdx.x;
    T val = 0;

    if (threadIdx.x < ld)
    {
        val = input[idx] + skip[idx];
        T rldval = rld * val;
        thread_data = pairSum(thread_data, kvp<T>(rldval, rldval * val));
    }

    layer_norm_small<T, TPB>(val, thread_data, ld, idx, beta, gamma, output);
}

template <typename T, unsigned TPB>
__global__ void skip_layer_norm_kernel(
    int ld, const T* input, const T* skip, const float* beta, const float* gamma, T* output)
{
    T rld = T(1) / T(ld);
    int offset = blockIdx.x * ld;

    cub::Sum pairSum;
    // reduce x and x^2
    kvp<T> thread_data(0, 0);

    for (int i = threadIdx.x; i < ld; i += TPB)
    {
        int idx = offset + i;
        T val = input[idx] + skip[idx];
        T rldval = rld * val;
        thread_data = pairSum(thread_data, kvp<T>(rldval, rldval * val));
        output[idx] = val;
    }

    layer_norm<T, TPB>(thread_data, ld, offset, beta, gamma, output);
}

template <typename T>
int compute_skip_layer_norm(
    cudaStream_t stream, int ld, int n, const T* input, const T* skip, const float* beta, const float* gamma, T* output)
{

    // this must be true because n is the total size of the tensor
    assert(n % ld == 0);
    const int gridSize = n / ld;

    if (ld <= 32)
    {

        const int blockSize = 32;
        skip_layer_norm_kernel_small<T, blockSize>
            <<<gridSize, blockSize, 0, stream>>>(ld, input, skip, beta, gamma, output);
    }
    else if (ld <= 128)
    {

        const int blockSize = 128;
        skip_layer_norm_kernel_small<T, blockSize>
            <<<gridSize, blockSize, 0, stream>>>(ld, input, skip, beta, gamma, output);
    }
    else if (ld == 384)
    {

        const int blockSize = 384;
        skip_layer_norm_kernel_small<T, blockSize>
            <<<gridSize, blockSize, 0, stream>>>(ld, input, skip, beta, gamma, output);
    }
    else
    {

        const int blockSize = 256;
        skip_layer_norm_kernel<T, blockSize><<<gridSize, blockSize, 0, stream>>>(ld, input, skip, beta, gamma, output);
    }
    CHECK(cudaPeekAtLastError());

    return 0;
}

using namespace nvinfer1;

// Clip plugin specific constants
namespace
{
static const char* SKIP_LAYER_NORM_VERSION{"1"};
static const char* SKIP_LAYER_NORM_NAME{"CustomSkipLayerNormPlugin"};
} // namespace

// Static class fields initialization
PluginFieldCollection SkipLayerNormPluginCreator::mFC{};
std::vector<PluginField> SkipLayerNormPluginCreator::mPluginAttributes;

REGISTER_TENSORRT_PLUGIN(SkipLayerNormPluginCreator);

SkipLayerNormPlugin::SkipLayerNormPlugin(
    const std::string name, const int ld, const Weights& beta, const Weights& gamma)
    : mLayerName(name)
    , m_ld(ld)
    , m_gamma(gamma)
    , m_beta(beta)
{
}

SkipLayerNormPlugin::SkipLayerNormPlugin(const std::string name, const void* data, size_t length)
    : mLayerName(name)
{
    gLogInfo << "Skip LN Deser start\n";
    // Deserialize in the same order as serialization
    const char* d = static_cast<const char*>(data);
    const char* a = d;
    DESER(d, mType);
    DESER(d, m_ld);
    DESER(d, mInputVolume);
    beta_dev = deser2dev<float>(d, m_ld);
    gamma_dev = deser2dev<float>(d, m_ld);
    assert(d == (a + length));
    // this signals init not to allocate/copy
    m_gamma.count = m_ld;
    m_gamma.values = nullptr;
    m_beta.count = m_ld;
    m_beta.values = nullptr;

    gLogInfo << "Skip LN Deser done\n";
}

const char* SkipLayerNormPlugin::getPluginType() const
{
    return SKIP_LAYER_NORM_NAME;
}

const char* SkipLayerNormPlugin::getPluginVersion() const
{
    return SKIP_LAYER_NORM_VERSION;
}

int SkipLayerNormPlugin::getNbOutputs() const
{
    return 1;
}

Dims SkipLayerNormPlugin::getOutputDimensions(int index, const Dims* inputs, int nbInputDims)
{
    // Validate input arguments
    assert(nbInputDims == 2);
    assert(index == 0);
    assert(inputs[0].nbDims == inputs[1].nbDims);
    for (int d = 0; d < inputs[0].nbDims; d++)
    {
        assert(inputs[0].d[d] == inputs[1].d[d]);
    }

    return inputs[0];
}

int SkipLayerNormPlugin::initialize()
{
    if (m_gamma.values)
    {
        cudaMalloc(&gamma_dev, sizeof(float) * m_gamma.count);
        cudaMemcpy(gamma_dev, m_gamma.values, sizeof(float) * m_gamma.count, cudaMemcpyHostToDevice);
    }
    if (m_beta.values)
    {
        cudaMalloc(&beta_dev, sizeof(float) * m_beta.count);
        cudaMemcpy(beta_dev, m_beta.values, sizeof(float) * m_gamma.count, cudaMemcpyHostToDevice);
    }
    return 0;
}

int SkipLayerNormPlugin::enqueue(int batchSize, const void* const* inputs, void** outputs, void*, cudaStream_t stream)
{
    int status = -1;

    // Our plugin outputs only one tensor

    // Launch CUDA kernel wrapper and save its return value
    if (mType == DataType::kFLOAT)
    {

        const float* input = static_cast<const float*>(inputs[0]);
        const float* skip = static_cast<const float*>(inputs[1]);
        float* output = static_cast<float*>(outputs[0]);
        status = compute_skip_layer_norm<float>(stream, m_ld, mInputVolume, input, skip, beta_dev, gamma_dev, output);
    }
    else if (mType == DataType::kHALF)
    {
        const half* input = static_cast<const half*>(inputs[0]);
        const half* skip = static_cast<const half*>(inputs[1]);
        half* output = static_cast<half*>(outputs[0]);

        status = compute_skip_layer_norm<half>(stream, m_ld, mInputVolume, input, skip, beta_dev, gamma_dev, output);
    }
    else
        assert(false);

    return status;
}

size_t SkipLayerNormPlugin::getSerializationSize() const
{
    return 2 * sizeof(float) * m_ld + sizeof(DataType) + sizeof(m_ld) + sizeof(mInputVolume);
}

void SkipLayerNormPlugin::serialize(void* buffer) const
{
    char* d = static_cast<char*>(buffer);
    const char* a = d;

    writeToBuffer(d, mType);
    writeToBuffer(d, m_ld);
    writeToBuffer(d, mInputVolume);
    serFromDev(d, beta_dev, m_ld);
    serFromDev(d, gamma_dev, m_ld);
    assert(d == a + getSerializationSize());
}

void SkipLayerNormPlugin::configureWithFormat(
    const Dims* inputs, int nbInputs, const Dims* outputs, int nbOutputs, DataType type, PluginFormat format, int)
{
    // Validate input arguments
    assert(nbOutputs == 1);
    assert(nbInputs == 2);

    // Fetch volume for future enqueue() operations
    size_t volume = 1;
    for (int i = 0; i < inputs->nbDims; i++)
    {
        volume *= inputs->d[i];
    }
    mInputVolume = volume;
    assert(inputs->nbDims == 5);
    assert(inputs->d[4] == 1);
    assert(inputs->d[3] == 1);
    m_ld = inputs->d[2];

    mType = type;
}

bool SkipLayerNormPlugin::supportsFormat(DataType type, PluginFormat format) const
{
    // This plugin only supports ordinary floats, and NCHW input format
    if (type == DataType::kFLOAT || type == DataType::kHALF)
        return format == PluginFormat::kNCHW;
    else
        return false;
}

void SkipLayerNormPlugin::terminate()
{
    gLogInfo << "SKIPLN terminate start" << std::endl;
    cudaFree(gamma_dev);
    cudaFree(beta_dev);
    gLogInfo << "SKIPLN terminate done" << std::endl;
}

void SkipLayerNormPlugin::destroy()
{
    // This gets called when the network containing plugin is destroyed
    delete this;
}

IPluginV2* SkipLayerNormPlugin::clone() const
{
    return new SkipLayerNormPlugin(mLayerName, m_ld, m_beta, m_gamma);
}

void SkipLayerNormPlugin::setPluginNamespace(const char* libNamespace)
{
    mNamespace = libNamespace;
}

const char* SkipLayerNormPlugin::getPluginNamespace() const
{
    return mNamespace.c_str();
}

SkipLayerNormPluginCreator::SkipLayerNormPluginCreator()
{
    mFC.nbFields = mPluginAttributes.size();
    mFC.fields = mPluginAttributes.data();
}

const char* SkipLayerNormPluginCreator::getPluginName() const
{
    return SKIP_LAYER_NORM_NAME;
}

const char* SkipLayerNormPluginCreator::getPluginVersion() const
{
    return SKIP_LAYER_NORM_VERSION;
}

const PluginFieldCollection* SkipLayerNormPluginCreator::getFieldNames()
{
    return &mFC;
}

IPluginV2* SkipLayerNormPluginCreator::createPlugin(const char* name, const PluginFieldCollection* fc)
{
    gLogError << "SkipLayerNormPluginCreator::createPlugin - not implemented\n";
    return nullptr;
}

IPluginV2* SkipLayerNormPluginCreator::deserializePlugin(const char* name, const void* serialData, size_t serialLength)
{
    // This object will be deleted when the network is destroyed, which will
    // call SkipLayerNormPlugin::destroy()
    return new SkipLayerNormPlugin(name, serialData, serialLength);
}

void SkipLayerNormPluginCreator::setPluginNamespace(const char* libNamespace)
{
    mNamespace = libNamespace;
}

const char* SkipLayerNormPluginCreator::getPluginNamespace() const
{
    return mNamespace.c_str();
}
