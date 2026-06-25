// ============================================================================
// asm.cpp -- a tiny two-pass RV32I assembler.
// ----------------------------------------------------------------------------
// Self-contained so the project needs no external RISC-V toolchain.  Emits a
// Verilog $readmemh image (one 32-bit word per line) where line N holds the word
// at byte address 4*N -- exactly what the RTL instruction/data memories expect.
//
// Supported: all RV32I base instructions, the `imm(reg)` load/store syntax, and
// the common pseudo-ops (nop, mv, li, j, jr, ret, beqz, bnez).  Labels may be
// used as branch/jump targets and, via `li`, as absolute addresses.
//
// Usage:  asm <input.s> <output.hex>
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <fstream>
#include <iostream>

struct Insn { uint32_t addr; std::vector<std::string> tok; int line; };

static std::map<std::string,int> REG = {
    {"x0",0},{"x1",1},{"x2",2},{"x3",3},{"x4",4},{"x5",5},{"x6",6},{"x7",7},
    {"x8",8},{"x9",9},{"x10",10},{"x11",11},{"x12",12},{"x13",13},{"x14",14},{"x15",15},
    {"x16",16},{"x17",17},{"x18",18},{"x19",19},{"x20",20},{"x21",21},{"x22",22},{"x23",23},
    {"x24",24},{"x25",25},{"x26",26},{"x27",27},{"x28",28},{"x29",29},{"x30",30},{"x31",31},
    {"zero",0},{"ra",1},{"sp",2},{"gp",3},{"tp",4},{"t0",5},{"t1",6},{"t2",7},
    {"s0",8},{"fp",8},{"s1",9},{"a0",10},{"a1",11},{"a2",12},{"a3",13},{"a4",14},{"a5",15},
    {"a6",16},{"a7",17},{"s2",18},{"s3",19},{"s4",20},{"s5",21},{"s6",22},{"s7",23},
    {"s8",24},{"s9",25},{"s10",26},{"s11",27},{"t3",28},{"t4",29},{"t5",30},{"t6",31}
};

static std::map<std::string,uint32_t> labels;

[[noreturn]] static void die(int line, const std::string& m) {
    std::cerr << "asm error (line " << line << "): " << m << "\n";
    std::exit(1);
}

static int reg(const std::string& s, int line) {
    auto it = REG.find(s);
    if (it == REG.end()) die(line, "bad register '" + s + "'");
    return it->second;
}

static int32_t imm(const std::string& s, int line) {
    if (labels.count(s)) return (int32_t)labels[s];
    try {
        size_t pos; int base = 10;
        std::string t = s;
        bool neg = false;
        if (!t.empty() && t[0]=='-') { neg=true; t=t.substr(1); }
        if (t.size()>2 && t[0]=='0' && (t[1]=='x'||t[1]=='X')) base=16;
        long v = std::stol(t, &pos, base);
        return neg ? -(int32_t)v : (int32_t)v;
    } catch (...) { die(line, "bad immediate/label '" + s + "'"); }
}

// Encoders -------------------------------------------------------------------
static uint32_t enc_r(int f7,int rs2,int rs1,int f3,int rd,int op){return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;}
static uint32_t enc_i(int imm,int rs1,int f3,int rd,int op){return ((imm&0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;}
static uint32_t enc_s(int imm,int rs2,int rs1,int f3,int op){return (((imm>>5)&0x7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&0x1f)<<7)|op;}
static uint32_t enc_b(int imm,int rs2,int rs1,int f3,int op){
    return (((imm>>12)&1)<<31)|(((imm>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((imm>>1)&0xf)<<8)|(((imm>>11)&1)<<7)|op;}
static uint32_t enc_u(int imm,int rd,int op){return (imm&0xfffff000)|(rd<<7)|op;}
static uint32_t enc_j(int imm,int rd,int op){
    return (((imm>>20)&1)<<31)|(((imm>>1)&0x3ff)<<21)|(((imm>>11)&1)<<20)|(((imm>>12)&0xff)<<12)|(rd<<7)|op;}

// Parse "imm(reg)" -> (imm, reg)
static void mem_operand(const std::string& s, int& im, int& rs, int line) {
    auto lp = s.find('('); auto rp = s.find(')');
    if (lp==std::string::npos || rp==std::string::npos) die(line,"bad mem operand '"+s+"'");
    im = imm(s.substr(0,lp), line);
    rs = reg(s.substr(lp+1, rp-lp-1), line);
}

int main(int argc, char** argv) {
    if (argc < 3) { std::cerr << "usage: asm <in.s> <out.hex>\n"; return 1; }
    std::ifstream in(argv[1]);
    if (!in) { std::cerr << "cannot open " << argv[1] << "\n"; return 1; }

    std::vector<Insn> prog;
    std::vector<uint32_t> raw;            // for .word literals, index aligned to prog
    std::string line; int lineno = 0; uint32_t addr = 0;

    // ----- Pass 1: addresses + labels --------------------------------------
    while (std::getline(in, line)) {
        lineno++;
        for (char& c : line) if (c=='#'||c==';') { line = line.substr(0, &c - &line[0]); break; }
        auto sl = line.find("//"); if (sl!=std::string::npos) line = line.substr(0,sl);
        for (char& c : line) if (c==',') c=' ';
        std::istringstream ss(line);
        std::vector<std::string> tok; std::string t;
        while (ss >> t) tok.push_back(t);
        size_t i = 0;
        while (i < tok.size() && tok[i].back()==':') {     // labels
            std::string nm = tok[i].substr(0, tok[i].size()-1);
            labels[nm] = addr; i++;
        }
        if (i >= tok.size()) continue;
        std::vector<std::string> rest(tok.begin()+i, tok.end());
        prog.push_back({addr, rest, lineno});
        // `li` always expands to lui+addi (2 words) so its size is fixed and
        // label addresses stay correct regardless of the constant's magnitude.
        addr += (rest[0] == "li") ? 8 : 4;
    }

    // ----- Pass 2: encode ---------------------------------------------------
    std::ofstream out(argv[2]);
    if (!out) { std::cerr << "cannot open " << argv[2] << "\n"; return 1; }

    auto emit = [&](uint32_t x){ char b[16]; std::snprintf(b, sizeof(b), "%08x", x); out << b << "\n"; };

    for (auto& in2 : prog) {
        auto& tk = in2.tok; int ln = in2.line; uint32_t pc = in2.addr;
        std::string op = tk[0];
        auto R = [&](int idx){ return reg(tk[idx], ln); };
        uint32_t w = 0;

        auto need = [&](size_t n){ if (tk.size() < n) die(ln, "too few operands for '"+op+"'"); };

        if (op==".word") { need(2); w = (uint32_t)imm(tk[1], ln); }
        else if (op=="nop") w = enc_i(0,0,0,0,0x13);
        else if (op=="mv")  { need(3); w = enc_i(0, R(2), 0, R(1), 0x13); }
        else if (op=="ret") w = enc_i(0,1,0,0,0x67);
        else if (op=="jr")  { need(2); w = enc_i(0, R(1), 0, 0, 0x67); }
        else if (op=="j")   { need(2); int off = imm(tk[1],ln) - (int)pc; w = enc_j(off, 0, 0x6f); }
        else if (op=="li") {
            // Always lui + addi (low-12 sign correction). Fixed 2-word size.
            need(3); int32_t v = imm(tk[2], ln);
            uint32_t hi = (v + 0x800) & 0xfffff000u;
            int32_t  lo = v - (int32_t)hi;
            emit(enc_u(hi, R(1), 0x37));        // lui rd, hi
            w = enc_i(lo, R(1), 0, R(1), 0x13); // addi rd, rd, lo (emitted by tail)
        }
        else if (op=="beqz"){ need(3); int off=imm(tk[2],ln)-(int)pc; w=enc_b(off,0,R(1),0,0x63); }
        else if (op=="bnez"){ need(3); int off=imm(tk[2],ln)-(int)pc; w=enc_b(off,0,R(1),1,0x63); }
        // R-type
        else if (op=="add") { need(4); w=enc_r(0x00,R(3),R(2),0,R(1),0x33); }
        else if (op=="sub") { need(4); w=enc_r(0x20,R(3),R(2),0,R(1),0x33); }
        else if (op=="sll") { need(4); w=enc_r(0x00,R(3),R(2),1,R(1),0x33); }
        else if (op=="slt") { need(4); w=enc_r(0x00,R(3),R(2),2,R(1),0x33); }
        else if (op=="sltu"){ need(4); w=enc_r(0x00,R(3),R(2),3,R(1),0x33); }
        else if (op=="xor") { need(4); w=enc_r(0x00,R(3),R(2),4,R(1),0x33); }
        else if (op=="srl") { need(4); w=enc_r(0x00,R(3),R(2),5,R(1),0x33); }
        else if (op=="sra") { need(4); w=enc_r(0x20,R(3),R(2),5,R(1),0x33); }
        else if (op=="or")  { need(4); w=enc_r(0x00,R(3),R(2),6,R(1),0x33); }
        else if (op=="and") { need(4); w=enc_r(0x00,R(3),R(2),7,R(1),0x33); }
        // I-type arithmetic
        else if (op=="addi"){ need(4); w=enc_i(imm(tk[3],ln),R(2),0,R(1),0x13); }
        else if (op=="slti"){ need(4); w=enc_i(imm(tk[3],ln),R(2),2,R(1),0x13); }
        else if (op=="sltiu"){need(4); w=enc_i(imm(tk[3],ln),R(2),3,R(1),0x13); }
        else if (op=="xori"){ need(4); w=enc_i(imm(tk[3],ln),R(2),4,R(1),0x13); }
        else if (op=="ori") { need(4); w=enc_i(imm(tk[3],ln),R(2),6,R(1),0x13); }
        else if (op=="andi"){ need(4); w=enc_i(imm(tk[3],ln),R(2),7,R(1),0x13); }
        else if (op=="slli"){ need(4); w=enc_i(imm(tk[3],ln)&0x1f,R(2),1,R(1),0x13); }
        else if (op=="srli"){ need(4); w=enc_i(imm(tk[3],ln)&0x1f,R(2),5,R(1),0x13); }
        else if (op=="srai"){ need(4); w=enc_i((imm(tk[3],ln)&0x1f)|0x400,R(2),5,R(1),0x13); }
        // loads
        else if (op=="lb"||op=="lh"||op=="lw"||op=="lbu"||op=="lhu") {
            need(3); int im,rs; mem_operand(tk[2],im,rs,ln);
            int f3 = op=="lb"?0:op=="lh"?1:op=="lw"?2:op=="lbu"?4:5;
            w = enc_i(im, rs, f3, R(1), 0x03);
        }
        // stores
        else if (op=="sb"||op=="sh"||op=="sw") {
            need(3); int im,rs; mem_operand(tk[2],im,rs,ln);
            int f3 = op=="sb"?0:op=="sh"?1:2;
            w = enc_s(im, R(1), rs, f3, 0x23);
        }
        // branches
        else if (op=="beq"||op=="bne"||op=="blt"||op=="bge"||op=="bltu"||op=="bgeu") {
            need(4); int off = imm(tk[3],ln) - (int)pc;
            int f3 = op=="beq"?0:op=="bne"?1:op=="blt"?4:op=="bge"?5:op=="bltu"?6:7;
            w = enc_b(off, R(2), R(1), f3, 0x63);
        }
        else if (op=="lui")  { need(3); w=enc_u(imm(tk[2],ln)<<12, R(1), 0x37); }
        else if (op=="auipc"){ need(3); w=enc_u(imm(tk[2],ln)<<12, R(1), 0x17); }
        else if (op=="jal") {
            if (tk.size()==2) { int off=imm(tk[1],ln)-(int)pc; w=enc_j(off,0,0x6f); }   // j-like
            else { need(3); int off=imm(tk[2],ln)-(int)pc; w=enc_j(off,R(1),0x6f); }
        }
        else if (op=="jalr") {
            if (tk.size()==2) w = enc_i(0, R(1), 0, 1, 0x67);                 // jalr rs
            else { need(4); w = enc_i(imm(tk[3],ln), R(2), 0, R(1), 0x67); }
        }
        else die(ln, "unknown instruction '" + op + "'");

        emit(w);
    }
    return 0;
}
