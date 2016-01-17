// Copyright (c) 2016 Anarchy Tools Contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import atpkg

#if os(Linux)
    import Glibc //need sleep
#endif

/**The ATllbuild tool builds a swift module via llbuild.
For more information on this tool, see `docs/attllbuild.md` */
final class ATllbuild : Tool {
    
    enum OutputType {
        case Executable
        case StaticLibrary
    }
    
    /**
     * Calculates the llbuild.yaml contents for the given configuration options
     *   - parameter sources: A resolved list of swift sources
     *   - parameter workdir: A temporary working directory for `atllbuild` to use
     *   - parameter modulename: The name of the module to be built.
     *   - returns: The string contents for llbuild.yaml suitable for processing by swift-build-tool
     */
    func llbuildyaml(sources: [String], workdir: String, modulename: String, linkSDK: Bool, compileOptions: [String], outputType: OutputType, linkWithProduct:[String], swiftCPath: String) -> String {
        let productPath = workdir + "products/"
        //this format is largely undocumented, but I reverse-engineered it from SwiftPM.
        var yaml = "client:\n  name: swift-build\n\n"
        
        yaml += "tools: {}\n\n"

        
        yaml += "targets:\n"
        yaml += "  \"\": [<atllbuild>]\n"
        yaml += "  atllbuild: [<atllbuild>]\n"
        
        //this is the "compile" command
        
        yaml += "commands:\n"
        yaml += "  <atllbuild-swiftc>:\n"
        yaml += "     tool: swift-compiler\n"
        yaml += "     executable: \"\(swiftCPath)\"\n"
        yaml += "     inputs: \(sources)\n"
        yaml += "     sources: \(sources)\n"
        
        //swiftPM wants "objects" which is just a list of %.swift.o files.  We have to put them in a temp directory though.
        let objects = sources.map { (source) -> String in
            workdir + "objects/" + source.toNSString.lastPathComponent + ".o"
        }
        yaml += "     objects: \(objects)\n"
        //this crazy syntax is how llbuild specifies outputs
        var llbuild_outputs = ["<atllbuild-swiftc>"]
        llbuild_outputs.appendContentsOf(objects)
        yaml += "     outputs: \(llbuild_outputs)\n"
        
        switch(outputType) {
        case .Executable:
            break
        case .StaticLibrary:
            yaml += "     is-library: true\n" //I have no idea what the effect of this is, but swiftPM does it, so I'm including it.
        }
        
        yaml += "     module-name: \(modulename)\n"
        let swiftModulePath = "\(productPath + modulename).swiftmodule"
        yaml += "     module-output-path: \(swiftModulePath)\n"
        yaml += "     temps-path: \(workdir)/llbuildtmp\n"
        
        var args : [String] = []
        args.appendContentsOf(["-j8", "-D","ATBUILD","-I",workdir+"products/"])
        
        if linkSDK {
            #if os(OSX) //we don't have SDKPath on linux
            args.appendContentsOf(["-sdk", SDKPath])
            #endif
        }
        args.appendContentsOf(compileOptions)
        
        yaml += "     other-args: \(args)\n"
        
        //and this is the "link" command
        yaml += "  <atllbuild>:\n"
        switch(outputType) {
        case .Executable:
            yaml += "    tool: shell\n"
            //this crazy syntax is how sbt declares a dependency
            var llbuild_inputs = ["<atllbuild-swiftc>"]
            llbuild_inputs.appendContentsOf(objects)
            let builtProducts = linkWithProduct.map {workdir+"products/"+$0}
            llbuild_inputs.appendContentsOf(builtProducts)
            let executablePath = productPath+modulename
            yaml += "    inputs: \(llbuild_inputs)\n"
            yaml += "    outputs: [\"<atllbuild>\", \"\(executablePath)\"]\n"
            //and now we have the crazy 'args'
            args = [swiftCPath, "-o",executablePath]
            args.appendContentsOf(objects)
            args.appendContentsOf(builtProducts)
            yaml += "    args: \(args)\n"
            yaml += "    description: Linking executable \(executablePath)\n"
            return yaml

        
        case .StaticLibrary:
            yaml += "    tool: shell\n"
            var llbuild_inputs = ["<atllbuild-swiftc>"]
            llbuild_inputs.appendContentsOf(objects)
            yaml += "    inputs: \(llbuild_inputs)\n"
            let libPath = productPath + modulename + ".a"
            yaml += "    outputs: [\"<atllbuild>\", \"\(libPath)\"]\n"
            
            //build the crazy args, mostly consisting of an `ar` shell command
            var shellCmd = "rm -rf \(libPath); ar cr '\(libPath)'"
            for obj in objects {
                shellCmd += " '\(obj)'"
            }
            let args = "[\"/bin/sh\",\"-c\",\(shellCmd)]"
            yaml += "    args: \(args)\n"
            yaml += "    description: \"Linking Library:  \(libPath)\""
            return yaml
        }
     }
    
    func run(task: Task) {
        //create the working directory
        let workDirectory = ".atllbuild/"
        let manager = NSFileManager.defaultManager()
        
        //NSFileManager is pretty anal about throwing errors if we try to remove something that doesn't exist, etc.
        //We just want to create a state where .atllbuild/objects and .atllbuild/llbuildtmp and .atllbuild/products exists.
        //and in particular, without erasing the product directory, since that accumulates build products across
        //multiple invocations of atllbuild.
        let _ = try? manager.removeItemAtPath(workDirectory + "/objects")
        let _ = try? manager.removeItemAtPath(workDirectory + "/llbuildtmp")
        let _ = try? manager.createDirectoryAtPath(workDirectory, withIntermediateDirectories: false, attributes: nil)
        let _ = try? manager.createDirectoryAtPath(workDirectory + "/products", withIntermediateDirectories: false, attributes: nil)
        let _ = try? manager.createDirectoryAtPath(workDirectory + "/objects", withIntermediateDirectories: false, attributes: nil)

        //parse arguments
        var linkWithProduct: [String] = []
        if let arr = task["linkWithProduct"]?.vector {
            for product in arr {
                guard let p = product.string else { fatalError("non-string product \(product)") }
                linkWithProduct.append(p)
            }
        }
        let outputType: OutputType
        if task["outputType"]?.string == "static-library" {
            outputType = .StaticLibrary
        }
        else if task["outputType"]?.string == "executable" {
            outputType = .Executable
        }
        else {
            fatalError("Unknown outputType \(task["outputType"])")
        }
        
        var compileOptions: [String] = []
        if let opts = task["compileOptions"]?.vector {
            for o in opts {
                guard let os = o.string else { fatalError("Compile option \(o) is not a string") }
                compileOptions.append(os)
            }
        }
        guard let sourceDescriptions = task["source"]?.vector?.flatMap({$0.string}) else { fatalError("Can't find sources for atllbuild.") }
                let sources = collectSources(sourceDescriptions, task: task)

        guard let name = task["name"]?.string else { fatalError("No name for atllbuild task") }
        
        let bootstrapOnly: Bool

        if task["bootstrapOnly"]?.bool == true {
            bootstrapOnly = true
        }
        else {
            bootstrapOnly = false
        }
        
        let sdk: Bool
        if task["linkSDK"]?.bool == false {
            sdk = false
        }
        else { sdk = true }
        
        let llbuildyamlpath : String

        if let value = task["llbuildyaml"]?.string {
            llbuildyamlpath = value
        }
        else {
            llbuildyamlpath = workDirectory + "llbuild.yaml"
        }

        let swiftCPath: String
        if let c = task["swiftCPath"]?.string {
            swiftCPath = c
        }
        else {
            swiftCPath = SwiftCPath
        }
        
        let yaml = llbuildyaml(sources, workdir: workDirectory, modulename: name, linkSDK: sdk, compileOptions: compileOptions, outputType: outputType, linkWithProduct: linkWithProduct, swiftCPath: swiftCPath)
        let _ = try? yaml.writeToFile(llbuildyamlpath, atomically: false, encoding: NSUTF8StringEncoding)
        if bootstrapOnly { return }
        
        //SR-566
        let cmd = "\(SwiftBuildToolpath) -f \(llbuildyamlpath)"
        if system(cmd) != 0 {
            fatalError(cmd)
        }
    }
}