pragma circom 2.0.0;

include "../circomlib/circuits/poseidon.circom";
include "../circomlib/circuits/comparators.circom";

template GuessCheck() {
    // --- PRIVATE INPUTS (solo A los conoce) ---
    signal input x;      // número secreto elegido por A
    signal input salt;   // sal aleatoria para el compromiso

    // --- PUBLIC INPUTS (visibles en blockchain) ---
    signal input h;      // compromiso publicado on-chain
    signal input y;      // intento del jugador B
    signal output equal; // resultado (1 si acierta, 0 si no)

    // --- Circuit logic ---
    component hash = Poseidon(2);
    hash.inputs[0] <== x;
    hash.inputs[1] <== salt;

    // Verifica que el hash corresponde al compromiso publicado
    hash.out === h;

    // Calcula si el número es correcto
    component eq = IsEqual();
    eq.in[0] <== x;
    eq.in[1] <== y;
    equal <== eq.out;
}

component main {public [h, y]} = GuessCheck();